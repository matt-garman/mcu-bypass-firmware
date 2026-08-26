# PIC12F675 feasibility — porting the reference architecture to a classic mid-range PIC

<!-- current-status:start -->
**Current status (v0.9.10; updated 2026-08-25): release-supported in software.**
The repository now contains the production Model-B PIC12F675 shell and pin map,
the complete three-variant build with flash and 48-of-64-byte Data-space gates,
static analysis,
shipping-source coverage, production-image return-stack and CONFIG gates,
oscillator-calibration image derivation, CLI gpsim functional tests,
selected-variant libgpsim I/O, lock-step and fault-injection lanes, the
long-duration soak, both authoritative aggregates over them, and the guarded
bench programming target.

PIC12F675 is **release-supported from `v0.9.9`** as the seventh software-validated
part. It is included in the default `all` goal, both CI aggregates, the canonical
21-image release set, the 18-combination release soak, and the 35-file retained
evidence inventory. The tag workflow rebuilds and requalifies its three shipping
images with the pinned PIC toolchain before publication.

The latest fully provisioned candidate build uses 548/574/585 of 1024 program words for the
simple/mute/relay variants. Persistent firmware state is 6 bytes (`ctx_`,
`ctx_check_`, `gpio_shadow_`, and `osccal_snapshot_`); XC8 reserves 40 of the
device's 64 Data-space bytes in all three variants. Every build requires one
consistent XC8 Data-space summary per variant and rejects use above 48 of those
64 bytes.

Like every current part, it has no controlled hardware-qualification record;
unlike some, it has no field-use report either (see
`HARDWARE_VALIDATION_LOG.md`, which keeps the two kinds of evidence apart).
Section 8 items 1, 2, 8, and 9 remain explicitly deferred to the `1.x.y`
hardware-validation pass. The guarded preflight/program/readback workflow
detects and records OSCCAL/BG changes and provides no real-programmer
factory-trim preservation guarantee.
<!-- current-status:end -->

The 2026-08-05 assessment, design rationale, spike provenance and proposed
sequencing are retained below as history. Sections 1 through 7, the original
sequence in §9, and the documentation plan in §11 intentionally retain their
preimplementation reasoning and prospective tense. Explicit current-status
notes override that historical text; it is not a statement that current
targets, tests, CI, or release integration are absent.

**What the 2026-08-05 assessment established:**

1. The **modular** architecture — the verified pure core `src/bypass_pure.c` and
   the three unmodified `src/bypass_output_*.c` drivers, compiled and linked into
   a hardware shell — **fits the PIC12F675 with roughly half its flash to
   spare**. Measured, not estimated. So this part would carry the same
   "the verified code is the shipped code" property as the PIC10F322, the AVR
   Classic parts and the ATtiny202. It would **not** need the hand-inlined
   treatment recorded in `pic10f320_special_case.md`.
2. The port needs **no new toolchain**: the same XC8, the same device pack, and
   the same simulator already installed for the PIC10F32x targets all support
   this part. Verified by building and by running firmware in the simulator.
3. The PIC12F675 is nevertheless **not a PIC10F322 variant**. It is a different
   CPU core generation with a different peripheral set, so the hardware shell is
   a rewrite, the pin map must change for an electrical reason, and the tick and
   watchdog become coupled in a way they are not on the 10F32x.
4. That flash headroom is enough to compile, link and run a gpsim trajectory for
   the **AVR's ISR-driven concurrency model**, where a timer ISR keeps integrating
   the footswitch *through* a blocking relay or mute actuation (§4.3). It does
   **not** establish return-stack feasibility: the PIC12F675 ISR build has no
   retained stack result, and its 8-level hardware stack is no larger than the
   PIC10F322's. The ISR model remains a candidate, not a recommendation, until a
   regenerated three-variant spike passes the current stack gate with a recorded
   result.
5. The validation tooling divides cleanly into three piles: lanes that port for
   free, lanes that need a **device-parameterization pass** on shared test cores
   that currently hard-code 10F32x register addresses, and one genuinely **new**
   piece of infrastructure (oscillator-calibration-word injection) with a real
   hardware-programming risk attached to it. Considering the ISR model adds a
   prerequisite measurement with the current stack gate — see §4.3.2 item 3.

**Measurement provenance:** 2026-08-05, `main` @ `0cfc72e`. The categorical ISR
recommendation entered in `59d55e9`; this document was corrected after the stack
gate changes in `56ad068` and `084ae09`. Those gate changes did **not** remeasure
the absent PIC12F675 ISR spike.

**Toolchain used for every figure below** — the same versions pinned in
`TOOLCHAIN.adoc`, with no additions:

| Tool | Version | Where |
|---|---|---|
| XC8 (free tier) | v3.10 | `/opt/microchip/xc8/v3.10/bin/xc8-cc` |
| Device pack | PIC10-12Fxxx DFP v1.9.189 | `/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8` |
| gpsim | 0.32.1 | system, plus `libgpsim.so.0` |
| cppcheck | 2.13.0 | system |

> Scope note: the measurements were taken with **throwaway spike shells** written
> outside the repository: a polled PIC12F675 shell, an ISR-driven variant of it,
> and an ISR-converted copy of the shipping `src/bypass_mcu_pic10f322.c`. Those
> spike sources remain absent. A later production Model-B implementation is now
> checked in; references below to "the spike" identify only the historical
> measurement source, not the current shell. §10 lists the edits behind each
> historical figure, which remain results that cannot be reproduced byte for byte
> from this repository alone.

---

## 1. Verdict

**Feasible under the polled Model B; the ISR model remains conditional on a
measured return-stack result.** There are no blocking unknowns in the toolchain.
In effort and in shape it resembles the ATtiny202 (AVR-XT) increment more than
either PIC increment: a new hardware shell against an already-proven core, plus a
test-infrastructure generalization, minus the toolchain archaeology that
dominated the AVR-XT work — because here the toolchain already exists and is
already pinned.

The three things that make it *not* trivial are all in §4: the footswitch cannot
sit on this part's input-only pin, there is no output latch register, and the
tick timer and the watchdog share one prescaler. Each is a design decision with a
correctness consequence, not a mechanical edit.

The two things that make it attractive are in §3 and §5: it fits the reference
architecture with ~500 words spare (against the 10F322's 39), and it costs
nothing in new tooling.

And one thing makes it *interesting* rather than merely feasible, in §4.3: that
same headroom lets an AVR-shaped ISR spike compile, link and run the tested gpsim
trajectory, while the PIC10F322 relay conversion cannot link. That is enough to
justify measuring the PIC12F675 ISR option, not enough to select it: its combined
main/interrupt return-stack peak and reserve remain unknown.

---

## 2. Why the PIC10F322 shell is not a starting point

The part numbers are adjacent; the silicon is not. The PIC10F32x is an
**enhanced mid-range** core; the PIC12F675 is a **classic mid-range** core. Every
row below was read from the device pack — `pic12f675.h` / `pic10f322.h`,
`12f675.ini` / `10f322.ini`, and `edc/PIC12F675.PIC` — and not from a summary.

| | PIC10F322 | PIC12F675 | Consequence |
|---|---|---|---|
| Core generation | enhanced mid-range | classic mid-range | shell is a rewrite, not a diff |
| Flash | 512 words (`ROMSIZE=200`) | **1024 words** (`ROMSIZE=400`) | §3: the architecture fits |
| RAM | 64 B | 64 B | comparable; see §3 |
| EEPROM | none | 128 B (unused) | `CPD` config bit exists |
| Hardware return stack | 8 (`STACKDEPTH=8`, `hwstackdepth="8"`) | 8 (identical capacity) | current gate handles polled and ISR graphs; polled 3/3/4 measured, PIC12F675 ISR result pending (§3.1, §4.3.2) |
| Interrupts | `INTCON.GIE`/`PEIE`, `PIE1.TMR2IE` — present, unused (Model B) | `INTCON.GIE`/`PEIE`/`T0IE`, `PIE1.TMR1IE` | both parts can; PIC12F675 ISR fits flash/RAM, return-stack affordability unmeasured (§4.3) |
| CONFIG word address | `0x2007` | `0x2007` | config lane ports structurally |
| I/O pins | 4: RA0–RA2 bidirectional, RA3 input-only | 6: GP0–GP2, GP4, GP5 bidirectional, GP3 input-only | 2 spare pins |
| Port registers | `PORTA` / `TRISA` / **`LATA`** | `GPIO` / `TRISIO` / **no LAT register** | §4.2 shadow latch |
| Analog disable | `ANSELA` | `ANSEL` **plus `CMCON`** (comparator holds GP0–GP1 analog out of reset; COUT modes also take GP2) **plus `ADCON0`** | §4.6 wider init + wider guard set |
| Weak pull-ups | `WPUA` bits 0–3 (**including** RA3) + `OPTION_REG.nWPUEN` | `WPU` bits 0,1,2,4,5 (**no GP3 bit**) + `OPTION_REG.nGPPU` | §4.1 pin map must change |
| Tick timer | TMR2 with `PR2` period register + `T2CON` | **no TMR2** — TMR0 (8-bit, no period reg) or TMR1 (16-bit, no period reg) | §4.4 tick redesign |
| WDT period control | `WDTCON.WDTPS`, independent of any timer | `OPTION_REG` `PSA`/`PS` — **one prescaler shared with TMR0** | §4.4 real coupling |
| Oscillator | `OSCCON.IRCF`, selectable; 2 MHz used | fixed 4 MHz INTOSC, **`OSCCAL`** trim register, no `OSCCON` | §4.5 `_XTAL_FREQ` 4 MHz; new failure mode |
| CONFIG fields | FOSC, WDTE, PWRTE, MCLRE, BOREN, BORV, LPBOR, CP, LVP, WRT | FOSC, WDTE, PWRTE, MCLRE, BOREN, CP, **CPD**, **BG** (bandgap calibration) | §4.7 |

### 2.1 SFR map, for the test-harness work

The shared libgpsim test cores address registers numerically, so the full map
matters. Note that on the classic core the second bank is genuinely a different
address (`0x081`, `0x085`, …), not an alias.

| Register | PIC10F322 | PIC12F675 | Notes |
|---|---|---|---|
| Port (read) | `PORTA` `0x005` | `GPIO` `0x005` | same address, different name |
| Direction | `TRISA` `0x006` | `TRISIO` `0x085` | bank 1 |
| Output latch | `LATA` `0x007` | — | does not exist |
| Analog select | `ANSELA` `0x008` | `ANSEL` `0x09F` | also carries `ADCS<2:0>` |
| Weak pull-up latch | `WPUA` `0x009` | `WPU` `0x095` | no bit 3 |
| Global pull-up enable | `OPTION_REG.nWPUEN` `0x00E` bit 7 | `OPTION_REG.nGPPU` `0x081` bit 7 | active low on both |
| Oscillator | `OSCCON.IRCF` `0x010` bits 6:4 | `OSCCAL` `0x090` (`CAL5:CAL0` in bits 7:2) | §4.5 |
| Tick period | `PR2` `0x012`, `T2CON` `0x013` | — | §4.4 |
| Tick flag | `PIR1.TMR2IF` | `INTCON.T0IF` bit 2 `0x00B` (or `PIR1.TMR1IF` bit 0 `0x00C`) | §4.4 |
| Watchdog period | `WDTCON.WDTPS` `0x030` bits 5:1 | `OPTION_REG` `PSA` bit 3, `PS<2:0>` bits 2:0 | §4.4 |
| Comparator | — | `CMCON` `0x019` (`CM<2:0>` bits 2:0) | §4.6 |
| ADC | — | `ADCON0` `0x01F` (`ADON` bit 0) | §4.6 |
| Reset status | — | `PCON` `0x08E` (`nPOR` bit 1, `nBOR`/`nBOD` bit 0) | optional new evidence source |

`OPTION_REG` bit positions on the PIC12F675: `nGPPU`=7, `INTEDG`=6, `T0CS`=5,
`T0SE`=4, `PSA`=3, `PS<2:0>`=2:0.

---

## 3. It fits: the measurement

This is the decisive result, and the reason this document exists rather than a
`pic12f675_special_case.md`.

The **real** `src/bypass_pure.c` and the **real, unmodified**
`src/bypass_output_{cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay}.c` were
compiled for the PIC12F675 against a spike shell carrying the complete defensive
layer — the full per-tick sanity gate, exact-`TRISIO` direction check, output
state check, pull-up integrity check, and a guarded-SFR check wider than the
10F322's (§4.8). Free-tier XC8 v3.10, `-O2`, the shipping optimization level:

| Variant | PIC12F675 (1024 words) | PIC10F322 (512 words), for scale |
|---|---|---|
| `cd4053_simple` | **494 w (48.2%)** | — |
| `cd4053_with_mute` | **520 w (50.8%)** | — |
| `tq2_l2_5v_relay` | **523 w (51.1%)** | 473 w (92.4%) |
| RAM | **36 / 64 B (56.2%)** | 34 / 64 B (53.1%) |

**~500 words free on the largest variant, against 39 free on the PIC10F322.**

Two observations worth recording:

- The comparison is not perfectly like-for-like and deliberately so: the spike
  shell's `hw_output_state_intact()` does *more* work than the 322's (it compares
  the shadow latch against expectation **and** the physical port against the
  shadow — see §4.2), and its guarded-SFR set is larger. The 12F675 figure is
  therefore, if anything, pessimistic relative to a minimal port.
- The classic core's bank-select overhead (`bcf`/`bsf STATUS,RP0` around every
  bank-1 access: `TRISIO`, `WPU`, `OPTION_REG`, `ANSEL`, `OSCCAL`) is already
  included in these numbers. It is real but it is not decisive at this flash size.

The `-Os` license cap documented in §2 of `pic10f320_feasibility.md` still
applies — it is the same free-tier compiler — but it is irrelevant here, because
nothing is near the ceiling.

All figures in this section are for a **Model B (polled)** shell, matching the
current PIC10F322 architecture. §4.3 prices ISR flash/RAM and records one gpsim
trajectory for the PIC12F675; it does not establish PIC12F675 ISR return-stack
feasibility. The PIC10F322 comparison is a flash/RAM build, not a second gpsim
trajectory claim.

### 3.1 Return-stack depth

The repository's hardware-return-stack gate, `test/check_stack_depth_pic.sh`, was
run against the polled spike assembly. The gate reads `STACKDEPTH=8` from
`12f675.ini`; `edc/PIC12F675.PIC` independently corroborates the hardware
capacity with `hwstackdepth="8"`. Its analysis oracles are instead the emitted
instruction-stream call graph and XC8's mandatory `callstack` directives:

```
STACK-DEPTH PASS [PIC12F675 cd4053_simple]:    3 + 2 reserve <= 8 levels (3 spare)
STACK-DEPTH PASS [PIC12F675 cd4053_with_mute]: 3 + 2 reserve <= 8 levels (3 spare)
STACK-DEPTH PASS [PIC12F675 tq2_l2_5v_relay]:  4 + 2 reserve <= 8 levels (2 spare)
```

These are historical **Model B** measurements. The deepest chain is the same
shape as the 10F322's, for the same reason
(`_main -> _init -> _hw_set_bypass_state -> _set_relay_coils_low -> _hw_pin_set_low`).
Under Model B this gate needs no work beyond a Makefile lane.

> **This result does not transfer to the ISR model.** The current gate does know
> that an interrupt tree is a second root, recognizes XC8 interrupt-context
> duplicates, and computes main tree + interrupt tree (including the hardware
> entry push). What is missing is a retained PIC12F675 ISR assembly and numeric
> result. See §4.3.2 item 3; §9 therefore measures before selecting the model.

---

## 4. Firmware: what ports, and what must be designed

### 4.0 What ports completely unchanged

`src/bypass_pure.c`, `src/bypass_pure.h`, `src/bypass_types.h`,
`src/bypass_config.h`, `src/bypass_hw_iface.h`, `src/bypass_static_assert.h`,
`src/bypass_compile_checks.h`, and all three `src/bypass_output_*.c` drivers with
their headers. `src/bypass_blocking_delay.h` already routes non-AVR builds to
XC8's `__delay_ms()`; only `_XTAL_FREQ` changes (§4.5).

New files: `src/bypass_mcu_pic12f675.c` and `src/bypass_pins_pic12f675.h`, plus a
`BYPASS_MCU_PIC12F675` arm in `src/bypass_output_common.h`.

### 4.1 The footswitch must move off the input-only pin

The PIC10F322 pin map rests on a happy coincidence: RA3 is input-only *and*
pull-up capable, so the one input goes on the one pin that cannot be an output,
freeing all three bidirectional pins for outputs.

**That coincidence does not exist on the PIC12F675.** The `WPU` register
implements bits 0, 1, 2, 4 and 5 only — there is no `WPU3`. GP3 is input-only
(shared with `MCLR`/`VPP`, a plain digital input when `MCLRE=OFF`) and has **no
internal weak pull-up**. Putting the footswitch there would make an external
pull-up mandatory and would delete `hw_footswitch_pullup_intact()` — one of the
defensive layer's checks — from this target.

The footswitch therefore moves to a bidirectional, pull-up-capable pin. The
package pinout, read from `edc/PIC12F675.PIC` (**not** from a web summary — the
project has been bitten by that once already):

| Pin | Functions |
|---|---|
| 1 | `Vdd` |
| 2 | `GP5` / `T1CKI` / `OSC1` / `CLKIN` |
| 3 | `GP4` / `AN3` / `T1G` / `OSC2` / `CLKOUT` |
| 4 | `GP3` / `MCLR` / `Vpp` |
| 5 | `GP2` / `AN2` / `T0CKI` / `INT` / `COUT` |
| 6 | `GP1` / `AN1` / `CIN-` / `Vref` / `ICSPCLK` |
| 7 | `GP0` / `AN0` / `CIN+` / `ICSPDAT` |
| 8 | `Vss` |

The spike used **GP5**, chosen because it is the one bidirectional pin carrying
no analog function — `ANSEL` implements `ANS0..ANS3` = GP0, GP1, GP2, GP4, and
the comparator's `CIN+`/`CIN-`/`COUT` are GP0/GP1/GP2. GP5 therefore needs no
`ANSEL` handling and cannot be silently re-analogized by an upset in either
`ANSEL` or `CMCON`. Its alternate functions are `OSC1`/`CLKIN` (released as I/O
by `FOSC=INTRCIO`, §4.7) and `T1CKI` (unconsumed — the recommended tick uses TMR0,
and even the TMR1 alternatives in §4.4 clock from Fosc/4 with `TMR1CS=0`).

Proposed map (the spike's, for review):

| Function | PIC10F322 | PIC12F675 |
|---|---|---|
| Footswitch (input + weak pull-up) | RA3 | **GP5** |
| Status LED | RA0 | GP0 |
| `CD4053_PIN` / `CD4053_CTL1` / `RELAY_RESET_PIN` | RA1 | GP1 |
| `CD4053_CTL2` / `RELAY_SET_PIN` | RA2 | GP2 |
| `BYPASS_OUTPUT_DDR_MASK` | `0x07` | `0x17` (GP0–GP2 plus parked GP4) |
| Spare | — | GP3 input with external ICSP-safe pull-up; GP4 output driven low |

Expected steady-state `TRISIO` is therefore `0x28` (GP0–GP2 and GP4 outputs;
GP3 and GP5 inputs), the direct analogue of the 322's exact-`TRISA` `0x08`.
GP4 follows the project's parked-spare policy: its direction, SRAM shadow,
physical pin level, and `ANSEL.ANS3` setting are guarded, and the board must
leave it unconnected or attach only a load safe while driven low. GP3 cannot be
parked in firmware because it is input-only and has no `WPU3`; the board must
provide an external pull-up compatible with ICSP/VPP programming.

The two spare pins remain available only by changing the hardware contract and
firmware together. The reference design deliberately constrains them rather
than leaving floating digital inputs: GP3 is externally pulled high and GP4 is
parked low.

**In-circuit programming parity.** The LED lands on `ICSPDAT` and the first
control pin on `ICSPCLK`, with `Vpp` on the input-only pin. That is exactly the
PIC10F322's situation (RA0 = ICSPDAT, RA1 = ICSPCLK, RA3 = MCLR/Vpp), so it is a
board-design consideration carried over unchanged, not a new hazard introduced by
this part.

### 4.2 No output latch register: the read-modify-write hazard

The classic mid-range core has no `LATx`. `GPIO` reads the **physical pin
levels**, not the last value written. So the idiom the 322 shell uses safely —

```c
void hw_pin_set_high(uint8_t const pin) { LATA |= (uint8_t)(1U << pin); }
```

— becomes a read-modify-write **on the pins** if written against `GPIO`, which is
the classic PIC defect: a loaded output (an LED through a resistor, a relay coil,
a pin still slewing) can read back a level different from the one written, and
the write-back then corrupts *other* bits in the same port.

The fix is a RAM shadow latch. All writes go shadow → `GPIO`:

```c
static uint8_t gpio_shadow_;
void hw_pin_set_high(uint8_t const pin) {
    gpio_shadow_ |=  (uint8_t)(1U << pin);
    GPIO = gpio_shadow_;
}
```

This has one pleasant consequence and two unpleasant ones, and all three belong
in the design record:

- **Pleasant:** the integrity check gets *stronger* than the 322's. With a shadow
  it becomes possible to compare intent against reality — the shadow against the
  expected mask, **and** the physical `GPIO` bits against the shadow. The second
  comparison catches a class of fault the 322 cannot see at all: a driver, pin or
  bus fault where the port does not follow the latch. The spike shell does both,
  and the cost is included in the §3 figures.
- **Unpleasant:** the shadow is SRAM, and SRAM is exactly what the project's
  cosmic-ray/EMI threat model says can flip. It becomes a new guarded location —
  but note that it guards *itself*: an upset in the shadow diverges it from either
  the expected mask or the port, and either way the gate fires. It should also be
  added to the fault-injection matrix as its own case. The matrix also changes a
  valid BYPASS context to ENGAGED without touching matching BYPASS shadow/GPIO,
  independently witnessing the shadow-versus-expected half rather than relying
  on a shadow upset that makes both comparisons false.
- **Unpleasant, and specific to GP2:** reading the port back makes the guard
  depend on the *DC input characteristics* of the output pins, and those are not
  uniform. DS41190G Table 1-1 makes GP2 the only Schmitt-Trigger input in this
  design's output set; GP0, GP1, GP3, GP4 and GP5 are TTL. The two are judged
  against different thresholds — D040 gives the TTL buffers V<sub>IH</sub> min
  2.0 V, D041 gives GP2 V<sub>IH</sub> min 0.8·V<sub>DD</sub> (4.0 V at 5 V) —
  while the drive side is characterized at a single point: D090 gives
  V<sub>OH</sub> min V<sub>DD</sub> − 0.7 V at I<sub>OH</sub> = −3.0 mA,
  V<sub>DD</sub> = 4.5 V, which is 3.8 V against a 3.6 V Schmitt threshold, and
  nothing at all is specified above 3 mA.

  `cd4053_with_mute` holds GP0|GP1|GP2 high in ENGAGED, so GP2's readback is
  judged at 0.8·V<sub>DD</sub> every 1.024 ms tick while its two neighbours are
  judged at 2.0 V. A pin that is driving its load *correctly* but whose
  V<sub>OH</sub> lands between 2.0 V and 0.8·V<sub>DD</sub> reads back low, the
  gate fires, and the shell watchdog-resets — permanently, because the condition
  is static.

  Both documented board options clear this comfortably, and it is worth being
  precise about why, because the two present different loads. On the CD4053
  board the MCU pin drives a **MOSFET gate**, with the analog switch
  level-shifted behind it, so the DC load is gate leakage. On the TMUX4053 the
  MCU pin drives the control input **directly**, and both boards additionally
  fit a **pulldown to ground** — the fail-safe that makes an undriven pin mean
  BYPASS (`DESIGN_DOCUMENTATION.adoc`, GPIO pin assignment and the
  CD4053-vs-TMUX4053 notes). That pulldown is the only real resistive load on
  the pin and the only part of it a builder chooses: at the design's 100 kΩ it
  draws 50 µA at 5 V, roughly 60× inside D090's characterized 3 mA point. The
  requirement therefore bites only on a substituted low-value pulldown, or on a
  builder who hangs something else off GP2 — which is exactly why it needs
  writing down. It is a board precondition that the shadow comparison
  *imports*, it belongs beside the GP3 and GP4 policies in
  `src/bypass_pins_pic12f675.h`, and no simulator lane can see it: gpsim models
  pins ideally. It belongs on the bench — §8 item 9.

`hw_configure_output_pins()` must initialize the shadow and `GPIO` together, and
`hw_output_state_intact()`'s `expected_high_mask` contract is unchanged from
`bypass_hw_iface.h` — the drivers do not need to know any of this.

### 4.3 Concurrency: ISR flash fits and gpsim runs; return-stack feasibility is pending

This is the most consequential finding in the document, and it is a consequence
of §3 rather than of any peripheral difference.

**The question.** The AVR shells are, loosely, two threads: the Timer0 ISR
samples and integrates the footswitch while `main()` runs the state machine, so
debounce keeps advancing *through* the 12 ms relay pulse and the 5 ms mute
delay — and `main()` sleeps in IDLE between ticks. Both PIC shells are Model B:
one polled loop, no ISR, sampling suspended for the duration of any blocking
actuation (`docs/phase2_pic_shell.md` §1 and §5).

**The answer has three parts:** peripheral capability yes; measured flash/RAM
fit yes; return-stack feasibility not yet established. The PIC10F322 has always
had `INTCON.GIE`/`PEIE` and `PIE1.TMR2IE`; Model B was
a choice, and one of its three stated payoffs was dissolving the shared-state
hazard. But that choice is now locked in by the budget. The real
`src/bypass_mcu_pic10f322.c` was converted to the ISR split — ISR, handshake
flag, `volatile ctx_`, flag protocol replacing the `TMR2IF` poll — and rebuilt:

| PIC10F322 (512 w) | polled (shipping) | ISR | Δ |
|---|---|---|---|
| `cd4053_simple` | 445 (86.9%) | 483 (94.3%) | +38 |
| `cd4053_with_mute` | 471 (92.0%) | **509 (99.4%)** | +38 |
| `tq2_l2_5v_relay` | 473 (92.4%) | **link fails** | — |
| RAM | 34 B (53.1%) | 43 B (67.2%) | +9 B |

The relay failure is worth quoting rather than paraphrasing, because it is far
closer than "does not fit" suggests:

```
error: (1347) can't find 0x2 words for psect "text18" in class "CODE"
       (largest unused contiguous range 0x1)
```

The linker needed a two-word contiguous range while the largest free range was
one word. The later map analysis in `non-blocking_output_schemes_feasibility.md`
places the build at 511/512 words, so this is fragmentation at the ceiling, not
a proof that the program is simply two words oversized. A leaner conversion
might genuinely land it. That is the wrong thing to optimize: it would mean
shipping three PIC10F322 images at
94.3%, 99.4% and ~100% of flash, on a part whose largest variant already leaves
only 39 words free. The honest reading is that the PIC10F322 is *at* the ceiling
for this architecture, not below it.

The same conversion on the PIC12F675:

| PIC12F675 (1024 w) | polled | ISR | Δ |
|---|---|---|---|
| `cd4053_simple` | 494 (48.2%) | 549 (53.6%) | +55 |
| `cd4053_with_mute` | 520 (50.8%) | 575 (56.2%) | +55 |
| `tq2_l2_5v_relay` | 523 (51.1%) | **578 (56.4%)** | +55 |
| RAM | 36 B (56.2%) | **46 B (71.9%)** | +10 B |

The +55 against the 322's +38 is not a core penalty and the two should not be
compared directly. The 12F675 ISR carries the divide-by-4 sub-tick that the
322's true-period TMR2 does not need (§4.4), plus two guards (`T0IE`, `GIE`)
that the 322 conversion was not given. How much of the 17-word gap is silicon
and how much is spike was not separated, because nothing turns on it: both
numbers land where they land against their own budgets.

The ISR-driven image was run in gpsim and produced the same tested engage / latch
/ bypass trajectory as the polled build (§6.1), demonstrating that the simulator
models the interrupt and timer path. That functional trajectory does not measure
the worst-case hardware return-stack peak or its reserve.

#### 4.3.1 What the ISR model would buy if the stack result passes

- **The behaviour matches the AVR.** Debounce integrates through the blocking
  actuation, which is the difference the user of a relay-equipped pedal could in
  principle feel.
- **`docs/phase2_pic_shell.md` §5 stops needing to exist.** That section is
  entirely an argument that the polled shell's ~12 ms sampling gap is benign. An
  ISR-integrated shell has no gap to defend.
- **So does its test-side consequence.** §5's closing line — *"any PIC timing
  test that counts ticks must budget for the actuation stealing them, or it will
  mis-measure the release gate"* — describes a real defect this tree has already
  paid for once, in the relay soak's release gate. An ISR-integrated PIC would
  use AVR-shaped budgets (modulo the 1.024 ms tick, §4.4.1).
- **The watchdog liveness proof gets stronger.** Model B pets unconditionally at
  the bottom of the loop, so reaching `CLRWDT` proves *one* thread is alive. The
  AVR pattern pets only on the ISR handshake, proving **both** are.

#### 4.3.2 What it costs

**1. The shared state is one byte, so the AVR's lock-free protocol ports
directly.** `docs/phase2_pic_shell.md` §6 warns that a future ISR "must add
explicit protection (disable interrupts around the access, or share only a
single byte)" because multi-byte objects are not atomic on an 8-bit core. That
warning is correct in general but over-broad for this design: the ISR touches
only `ctx_.debounce_counter` — a `uint8_t` — and the `timer_isr_called_` flag.
`program_state` and `effect_state` are written exclusively by `main()`, so their
being 2-byte `int` under XC8 is irrelevant to atomicity. **The consequence is
that the AVR's protocol ports without needing `-fshort-enums`, which is exactly
the property §6 assumed a PIC could not have.** That section should be corrected
whether or not this port happens.

**2. XC8 silently duplicates functions reachable from both contexts.** The build
emits:

```
advisory: (1510) non-reentrant function "_hw_read_footswitch" appears in
multiple call graphs and has been duplicated by the compiler
```

XC8 has no data stack — locals live in a statically overlaid compiled stack — so
a function called from both `main()` and the ISR gets a second copy
(`i1_hw_read_footswitch`) rather than risking overlay corruption under
reentrance. It is automatic and its cost is already inside the word counts
above, but it is silent and it scales with how much the two contexts share.

**3. The hardware return-stack bound must be measured before this model is
selected.** At the time of the original spike, the then-current
`test/check_stack_depth_pic.sh` failed on the ISR build:

```
FAIL: [PIC12F675-ISR tq2_l2_5v_relay] i1_hw_read_footswitch is never called
      but XC8 does not list it as an entry point
```

That diagnostic exposed the `i1_` lexer defect fixed in `56ad068`; `084ae09`
later removed target-prefix assumptions and hardened psect/call parsing. The
current gate recognizes interrupt-context duplicates, sums the main and ISR
trees, and includes the hardware-pushed interrupt return address. The old
failure is historical, not a current limitation.

The *quantity* still changes: an interrupt can fire at `main()`'s deepest point,
so the bound becomes **main's deepest chain + the ISR tree including its entry
push**, against 8 levels and the project's 2-level reserve. The polled relay main
tree measured 4 (§3.1), but the ISR build can change both graphs. No source,
assembly or current-gate output from that PIC12F675 ISR spike was retained, so
there is no numeric result to cite. XC8's prose annotation cannot substitute for
one: the gate re-derives the instruction-stream chain and requires XC8's
`callstack` directives as corroboration.

This is why §9 makes the stack work a **prerequisite** of the ISR decision
rather than a follow-up.

**4. RAM becomes the tighter measured storage resource.** 46 of 64 bytes (71.9%),
up from 36. It inverts the PIC10F322's measured flash/RAM situation, but cannot
be called the binding resource until the unmeasured return-stack result exists.

Two smaller items: the fault harness's behaviourally identified main-loop
`CLRWDT` anchor must be re-established against the new loop shape, and there is a
design choice about whether the per-tick sanity gate runs once per tick (AVR
shape, gate inside the handshake) or on every busy-wait spin.

#### 4.3.3 What it does *not* buy: sleep

The AVR gets a second benefit from its ISR that the PIC cannot have. On AVR,
IDLE sleep halts the core while leaving the peripheral clock running, so Timer0
keeps counting and the ISR still wakes it. **PIC `SLEEP` stops the system
oscillator outright — there is no IDLE-equivalent mode.** A TMR0 or TMR1 clocked
from Fosc/4 stops dead and can never generate the wake-up.

The only timer that survives `SLEEP` on this part is Timer1 in asynchronous mode
off the Timer1 (LP) oscillator, and the device pack is explicit about which pins
that is: *"LP oscillator: Low power crystal on GP4/OSC2/CLKOUT and
GP5/OSC1/CLKIN"*. That consumes **both** spare pins **and** GP5 — the pin §4.1
assigns to the footswitch — and adds an external 32.768 kHz crystal to a design
that currently needs no external timing component. It is not a trade this design
would make.

So a PIC12F675 ISR design, **if accepted after the stack measurement**, would get
the concurrency but keep a busy-waiting `main()`. That is a real difference from
the AVR and should be stated plainly rather than implied — but it costs nothing
that matters here, because `docs/phase2_pic_shell.md` §1 already books the same
trade for the PIC10F322:
*"Accepted trade-off: no low-power sleep. Fine for an always-powered pedal."*

The WDT-periodic-wakeup loop ("Model A") that *would* sleep was considered and
rejected for the PIC10F322 for reasons that apply here unchanged, and it is a
different architecture from the one this section is about.

#### 4.3.4 Recommendation

**Do not select the ISR model yet.** Its measured flash/RAM fit, tested gpsim
trajectory, AVR behaviour parity and test-budget simplification make it a strong
candidate, but none establishes that the combined call graph fits the 8-level
stack with the required 2-level reserve. Model B is the only model this document
currently establishes as feasible. Before choosing ISR, regenerate
all three spike variants, run the current gate, and retain the source/patch,
exact toolchain command, generated assembly (or immutable hashes) and complete
gate output. If every variant passes with an accepted margin, the benefits above
support selecting it; if not, use Model B or flatten the spike and remeasure
before production-shell work.

If the ISR model passes that decision gate, §4.4 below is still the right tick
source — the difference is that `T0IF` raises an interrupt instead of being
polled — and the guard set in §4.8 gains `INTCON.GIE`, `INTCON.T0IE` and the
handshake flag's range check.

### 4.4 The tick source and the watchdog prescaler

This is the trap, and it is the item most likely to be missed by someone reading
only the part summary. It applies to the polled and ISR models alike: both need
a ~1 ms time base, and both need the watchdog to outlast a blocking actuation.

The PIC12F675 has **no TMR2 and no period register anywhere**. TMR0 is 8-bit and
free-running to overflow; TMR1 is 16-bit and free-running to overflow; there is
no CCP module. And `OPTION_REG.PSA` assigns **one** prescaler to *either* TMR0
*or* the watchdog — never both.

At 4 MHz INTOSC the instruction clock is Fosc/4 = 1 MHz (1 µs per instruction
cycle). The options:

| Option | Tick | Watchdog | Verdict |
|---|---|---|---|
| TMR0, prescaler on TMR0 at 1:4 | 1.024 ms per rollover, no software counting | **WDT loses the prescaler → ~18 ms nominal** | **Rejected.** Shorter than the 12 ms relay coil pulse plus a tick. The relay variant would reset itself mid-actuation. |
| TMR1 at 1:1, preload `0xFC18` each tick | exactly 1.000 ms nominal | prescaler free for WDT | Works, but the reload latency is a per-tick skew, and 16-bit access on this core is non-atomic (read low/high/re-read high). More moving parts. |
| TMR1 at 1:1, 16-bit deadline compare | exactly 1.000 ms, no skew | prescaler free for WDT | More code, same non-atomic-read caveat. |
| **TMR0 at 1:1, count 4 rollovers in software** | 4 × 256 µs = **1.024 ms** | **prescaler free for WDT** | **Recommended.** Simplest, 8-bit, no reload, no atomicity question. |

With the prescaler assigned to the watchdog (`PSA=1`), the available periods are
18 ms × `2^PS`:

| `PS<2:0>` | Ratio | Nominal period |
|---|---|---|
| 000 | 1:1 | 18 ms |
| 011 | 1:8 | 144 ms |
| **100** | **1:16** | **288 ms** |
| 101 | 1:32 | 576 ms |
| 111 | 1:128 | 2.304 s |

**1:16 → ~288 ms** is the closest analogue to the PIC10F322's ~256 ms and is what
the spike used. Its early rough margin estimate was one tick (1.024 ms) plus the
longest blocking actuation (12 ms relay coil pulse), or about **13.1 ms**. The
production compile-time bound is deliberately more conservative: it ceilings
the tick to 2 ms and adds 2 ms of bounded loop work, for **16 ms** against the
de-rated floor below.

**The 18 ms base above is a NOMINAL period, and the argument does not rest on
it** (datasheet read 2026-08-11, §8 item 4). Both figures in play are
DS41190G's own, and they are different *kinds* of number rather than a
discrepancy to reconcile. §9.6.1 "WDT PERIOD" states in its own prose: "The WDT
has a nominal time-out period of **18 ms**, (with no prescaler)" — that is
where the 18 ms base and the 288 ms row come from, and gpsim models the same
figure. Table 12-4 parameter 31 `TWDT` then *characterizes* the unprescaled
period as **10 ms min / 17 ms typ / 25 ms max** (30 ms max at extended
temperature), so the characterized typical is 17 ms and 1:16 is 272 ms typical
rather than 288 ms. A watchdog margin argument may not be built on a nominal or
a typical at all. The one that matters is the **minimum: 10 ms × 16 = 160 ms**,
which is what the shell cites and what its conservative 16 ms bound is judged
against -- a factor of 10.

Simulation confirms the model exactly: with `PSA=1, PS=1:16` a starved watchdog
reset fired at **cycle 288,039**, i.e. 288.0 ms at 1 MIPS — precisely 18 ms × 16
(§6.1).

#### 4.4.1 The tick is 1.024 ms, not 1.000 ms — and that propagates

A 2.4% stretch is inconsequential for debounce behaviour and changes **nothing**
in the pure core (which counts samples, not milliseconds). It does change every
*physical* timing figure this repository asserts:

| Quantity | AVR (ISR-driven) / PIC10F322 (polled) | PIC12F675 |
|---|---|---|
| `PRESSED_THRESH` = 8 samples | 8.0 ms | 8.19 ms |
| `RELEASE_THRESH` = 25 samples | 25.0 ms | 25.6 ms |
| Pure-model 33-sample minimum between press onsets | 33 ms | **33.8 ms** |
| Soak budget, simple variant | 33 ms | ~34 ms |
| Soak budget, mute variant (+5 ms block) | 38 ms | ~39 ms |
| Soak budget, relay variant (+12 ms block) | 45 ms | ~46 ms |

The qualification budgets in the last three rows are the ones documented in
`test/README.md`. The soak driver does not read them as constants — it derives
its holds, and since the step 9 lane it derives them **through** the tick period
rather than assuming one. `test/pic/test_soak_pic_core.h` now reads

```c
#define SOAK_TICKS_MS(ticks)  (((ticks) * SOAK_TICK_US + 999u) / 1000u)
#define SOAK_PRESS_HOLD_MS    (SOAK_TICKS_MS(PRESSED_THRESH) + SOAK_ACTUATION_BLOCK_MS + 10u)
#define SOAK_RELEASE_HOLD_MS  (SOAK_TICKS_MS(RELEASE_THRESH) + SOAK_ACTUATION_BLOCK_MS + 10u)
```

with `CYCLES_PER_MS = (F_CPU_HZ / 4) / 1000` and the tick period stated by the
part adapter — `SOAK_TICK_US` is 1000 on the PIC10F32x parts and 1024 here. <!-- name-contract: exempt (C adapter macro, not a Make variable) -->
Three things follow. First, the cycle conversion was **already** parameterized by
clock and becomes 1000 (from 500) at 4 MHz with no code change. Second, the hold
expressions used to assume **one tick == one millisecond**, which stops being
true at 1.024 ms: `THRESH` ticks take `THRESH × 1.024` ms, so the release hold
was short by ~0.6 ms against its own intent. The existing 10 ms slack would have
absorbed that comfortably at these threshold values — but that slack is already
load-bearing for a different reason (a blocking actuation steals integration
ticks from the polled loop), and one margin covering two unrelated errors reports
neither when it finally runs out. So it is now **stated and re-derived**, not
absorbed. Third, the conversion rounds **up** and is exact at 1.000 ms: the
PIC10F32x holds are the numbers they always were, which is what allowed all six
shipping soak binaries to stay byte-identical across the change.

The blocking actuation is added in **milliseconds** on every part and does not
scale with the tick: a coil pulse and a mute delay are wall-clock `__delay_ms()`
waits in the shared output drivers, so a block of *B* ms costs *B* ms of tick
accumulation whatever the tick period is.

The alternative — a TMR1-based exact 1.000 ms tick — buys numerical parity with
every other target and makes this whole subsection disappear, at the cost of the
complexity in the §4.4 table. **This is a genuine fork in the design and should
be decided deliberately, not defaulted.**

The polled-loop tick wait also gains an inner loop (four `T0IF` waits instead of
one `TMR2IF` wait). This does not disturb the max-block invariant — the blocking
quantity is still the actuation delay, not the tick — but the fault harness's
"behaviourally identified main-loop `CLRWDT`" anchor must be re-established
against the new loop shape.

### 4.5 Fixed 4 MHz INTOSC, and the OSCCAL calibration word

There is **no `OSCCON`** on this part and no runtime frequency selection: the
internal oscillator is 4 MHz, trimmed by `OSCCAL.CAL5:CAL0` in bits 7:2; bits
1:0 are unimplemented and read zero. So:

- `_XTAL_FREQ` becomes `4000000UL`, with the corresponding `static_assert`. The
  drivers' `__delay_ms(12)` / `__delay_ms(5)` are unaffected in *milliseconds*.
- The 322 shell's `OSCCON.IRCF` guard has no counterpart. The proposed analogue is
  to **snapshot `OSCCAL` at the end of `hw_mcu_init()` and compare it every tick**.
  The expected value is device-specific (it is factory trim), so it cannot be a
  compile-time constant — it has to be a captured shadow, structurally like the
  `GPIO` shadow in §4.2.

**The calibration value lives in flash, at the last program word, and its absence
is fatal.** `edc/PIC12F675.PIC` declares it explicitly:

```xml
<edc:CalDataZone edc:beginaddr="0x3ff" edc:endaddr="0x400"
                 edc:issection="true" edc:regionid=".oscval"
                 edc:sectiondesc="Oscillator value" edc:sectionname="OSCVAL"/>
```

XC8's startup code emits `call 0x3ff` and expects a factory-programmed `RETLW`
there. This was observed the hard way in the spike: running an unmodified XC8
`.hex` in gpsim, the program counter ran off the end of flash
(`increment PC=0x400 == memory size 0x400`), the part watchdog-reset, and it did
so **in a loop** — `main()` was never reached. Appending `RETLW 0x80` (opcode
`0x3480`) at word `0x3FF` fixed it immediately, and `OSCCAL` read back `0x80`.

Consequences, both real:

- **For simulation:** every gpsim-based lane needs a calibration-word injection
  step in front of it (§6.2). Nothing analogous exists for the 10F32x.
- **For hardware:** a bulk erase that does not preserve word `0x3FF` leaves a
  device whose oscillator is untrimmed, which on this design means every
  `__delay_ms()` pulse width and the whole tick cadence are wrong. This must
  become a documented, gated part of the programming procedure, not a footnote.
  See §8.

### 4.6 The comparator and ADC are a new hazard surface

On the PIC10F322 the only analog encroachment is `ANSELA`. On the PIC12F675 there
are three:

- **`CMCON`** — `CM<2:0> = 000` out of reset is "Comparator Reset" mode
  (DS41190G Figure 6-2), which makes GP0/CIN+ and GP1/CIN- **analog inputs**;
  §3.1 says an analog input "always reads 0" whatever the pin is driving. GP2 is
  **not** taken at reset — §6.4 puts `COUT` on it in three of the eight modes,
  which is an upset path rather than the reset state. Note the mechanism: §3.1
  is explicit that `TRISIO` still controls direction "even when they are being
  used as analog inputs", so what the reset state breaks is **readback**, not
  drive — which is precisely why the §4.2 port-follows-shadow comparison is the
  check that catches it, and why leaving `CM<2:0> = 000` would fail that check
  on every tick. `CMCON = 0x07` (`CM<2:0> = 111`, comparator off) is mandatory
  in init, and is a new guarded SFR.
- **`ANSEL`** — clears and guards `ANS0..ANS3` for GP0/GP1/GP2/GP4. GP4 is GPIO
  bit 4 but `ANS3` is ANSEL bit 3, so the GPIO output mask cannot be reused for
  this comparison. ANSEL also carries `ADCS<2:0>` in bits 6:4, which do not
  matter with the ADC off.
- **`ADCON0.ADON`** — must be 0, and is worth guarding for the same reason
  `CMCON` is.

Each of these is a single-event-upset path to "the firmware still thinks it owns
a digital output but an analog peripheral has taken it". CMCON reaches all three
active outputs — GP0 and GP1 at reset, GP2 only through a COUT mode; ANSEL also
covers parked GP4 through ANS3. The 322 has one such
path; this part has three.

### 4.7 CONFIG word

Same address (`0x2007`), different fields. From `edc/PIC12F675.PIC`:

| Field | Mask | Proposed setting | Note |
|---|---|---|---|
| `FOSC<2:0>` | `0x7` | `INTRCIO` | INTOSC with **I/O** on both GP4 and GP5 — required, since GP5 is the footswitch |
| `WDTE` | `0x1` | `ON` | watchdog not software-disableable |
| `PWRTE` | `0x1` | `ON` | power-up timer |
| `MCLRE` | `0x1` | `OFF` | GP3 becomes a digital input, `MCLR` internally tied to VDD |
| `BOREN` | `0x1` | `ON` | see §8 on the trip point |
| `CP` | `0x1` | `OFF` | |
| `CPD` | `0x1` | `OFF` | **new** — data (EEPROM) code protection; no 10F322 counterpart |
| Reserved | `0x7` | — | unimplemented |
| `BG<1:0>` | `0x3` | **factory calibration** | **new, and a risk — see §8** |

Absent relative to the 10F322: `LVP`, `WRT`, `BORV`, `LPBOR`. The 322 shell's
CONFIG rationale comment block, and `test/pic/test_config_pic.c`'s decode table,
both need a part-specific rewrite — but the *mechanism* (parse the word out of
the HEX at `0x2007`, decode, compare against documented intent) ports directly.

Measured: for the settings above XC8 emits `CONFIG = 0x31CC`, decoding as
`FOSC=4 (INTRCIO)`, `WDTE=1 (ON)`, `PWRTE=0 (ON, active low)`, `MCLRE=0 (OFF)`,
`BOREN=1 (ON)`, `CP=1 (OFF)`, `CPD=1 (OFF)`, `BG=0b11`.

### 4.8 Proposed guarded-SFR set

Putting §4.1–§4.7 together, the per-tick sanity gate for this part would guard:

| Guarded item | PIC10F322 counterpart | Status |
|---|---|---|
| Exact `TRISIO` (`& 0x3F`, expect `0x28`) | exact `TRISA` (`& 0x0F`, expect `0x08`) | ported; GP4 parked low |
| Output shadow vs expected mask | `LATA` vs expected mask | ported |
| Physical `GPIO` vs shadow | — | **new** (§4.2) |
| `ANSEL & 0x0F == 0` | `ANSELA & mask == 0` | ported; ANS3 maps to GPIO GP4 |
| `CMCON & 0x07 == 0x07` | — | **new** (§4.6) |
| `ADCON0.ADON == 0` | — | **new** (§4.6) |
| `WPU & 0x37` exactly `1 << FOOTSW_PIN` | `WPUA & 0x0F` exactly `1 << FOOTSW_PIN` | ported, mask excludes the absent bit 3 |
| `OPTION_REG.nGPPU == 0` | `OPTION_REG.nWPUEN == 0` | ported |
| `OPTION_REG` exact (carries `PSA`/`PS` — the WDT period — **and** `T0CS` — the tick clock source — **and** `nGPPU`) | `WDTCON.WDTPS`, `PR2`, `T2CON` separately | **consolidated**; one register now carries three safety-relevant fields |
| `OSCCAL` vs captured snapshot | `OSCCON.IRCF` vs constant | **changed** (§4.5) |
| `ctx_` range checks | identical | ported |
| `INTCON.GIE == 1`, `INTCON.T0IE == 1` | — (no ISR on either PIC today) | **ISR model only** (§4.3); the AVR-shell analogue of proving the tick source is still armed |
| `timer_isr_called_` range check | AVR shell's identical check | **ISR model only** (§4.3) |

The last two rows are conditional on a future positive §4.3 stack decision. They are listed here rather
than in §4.3 because the fault-injection matrix is built from this table, and
`PIC_FAULT_EXPECTED_CHECKS` has to be right for whichever model is chosen. <!-- name-contract: exempt (C adapter macro, not a Make variable) -->

**The inverse direction — a spurious *arm* — is deliberately not guarded.** The
two rows above prove the tick source is still armed, which is a hazard only when
an ISR exists. Under Model B the mirror-image hazard is an upset that *enables*
interrupts where no handler exists, so it is worth recording why `INTCON` is
absent from the guard set rather than leaving the omission unexamined.

It costs two coincident flips, which puts it outside a single-event threat
model. The DFP's `edc/PIC12F675.PIC` gives `INTCON` `por="00000000"` with all
eight bits implemented, and the shell writes exactly two of them: `GIE = 0` in
`hw_force_wdt_reset()`, and `T0IF` in `hw_tick_timer_start()` and the tick
loop. No enable bit is ever set, so `GIE` alone vectors nowhere. `T0IF` *is*
set every 256 us by the free-running timer, which makes `GIE` + `T0IE` the
cheapest path — and that is still two.

The consequence if it happened is also mild, though this part is an observation
about the built images rather than a design invariant. XC8 places the OSCCAL
restore at `0x000`–`0x003`, which falls through into the interrupt vector, so
`0x004` holds `GOTO 0x3F8` in all three shipping images — and `0x3F8` is XC8's
`__initialization`, which clears RAM and ends in `GOTO 0x347`, `_main` (both
symbols are in the per-variant `.sym`). A spurious interrupt would therefore
re-run the C startup and re-enter `main()`: a warm restart into a fully
re-initialized part, costing one hardware stack level to the pushed return
address (peak depth is 3–4 of 8 with 2 reserved, so it is absorbed) and leaving
the effect in `BYPASS`. Hardware clears `GIE` on entry and the firmware never
sets it, so it cannot repeat without a second upset, and the watchdog backstops
any layout where the vector did lead somewhere that hung.

None of that is load-bearing: the reason to leave `INTCON` out is the two-flip
cost, not XC8's current placement, which a code or optimization change could
move. The PIC10F322 shell has the identical posture — `INTCONbits.GIE = 0`
appears only in its force-reset path, and its guard set omits `INTCON` too — so
this is a repo-wide position, not something new to this part.

The `OPTION_REG` consolidation is worth calling out in review: on the 322 an
upset to the WDT period, the tick period and the pull-up enable are three
independent events in three registers; here they are three fields in one byte, so
a single-bit upset is *more* likely to hit something safety-relevant, and one
exact comparison covers all of it.

---

## 5. Toolchain: nothing new is required

All three verified directly:

- **XC8 v3.10** targets the part with the already-installed pack:
  `xc8-cc --chipinfo` lists `12F675:400:2`, and real images built and linked
  cleanly at `-std=c99 -O2` (§3).
- **PIC10-12Fxxx DFP v1.9.189** — the pack already pinned for the 10F32x targets —
  ships `pic12f675.h`, `pic12f675.inc`, `12f675.cgen.inc`, `pic/dat/ini/12f675.ini`
  and `edc/PIC12F675.PIC`. No new download or hash is needed, but the shared
  installer and `test-supply-chain` require the extracted `pic12f675.h` before
  declaring that DFP installation complete.
- **cppcheck 2.13.0** has the `pic8` platform (classic mid-range) alongside the
  `pic8-enhanced` platform used for the 322 — both confirmed present. The
  `pic10f322-analyze-cppcheck` / `-misra` recipes port with a platform swap and a
  device-macro swap; the DFP/XC8 include paths and suppression patterns are
  already shared.
- **gpsim 0.32.1** supports `p12f675` (and `p12f629`) — §6.

---

## 6. Simulation and validation tooling

### 6.1 gpsim runs this part, and models what the lanes depend on

`gpsim` 0.32.1's processor list includes `pic12f675` and `pic12f629` alongside
`pic10f320` / `pic10f322`. That the name exists proves nothing on its own, so the
capabilities the lanes actually rely on were exercised against a real
XC8-compiled image of the **modular** firmware (real core, real
`bypass_output_cd4053_simple.c`, spike shell), with the footswitch driven by an
`asynchronous_stimulus`:

```
INIT_BYPASS     gpio=0x00   trisio=0x28     (GP0-GP2/GP4 outputs, GP3/GP5 inputs)
ENGAGED         gpio=0x03   (LED + CD4053 control high after a debounced press)
STILL_ENGAGED   gpio=0x23   (state latched across release; GP5 high = released)
BYPASS_AGAIN    gpio=0x00   (toggled back on the second press)
```

That is the complete engage/latch/bypass trajectory of the shipping design,
running on simulated PIC12F675 silicon. Confirmed modelled along the way:

| Capability | Needed by | Evidence |
|---|---|---|
| Weak pull-ups (`WPU` + `nGPPU`) | fault, io, lockstep, soak, gpsim CLI | with no stimulus attached, `GPIO` read `0x20` — GP5 pulled high by the internal pull-up alone |
| `TRISIO` direction | io, fault | `trisio=0x28` as configured; parked GP4 remains an output |
| TMR0 / `INTCON.T0IF` tick | every lane | the debounce reached threshold and toggled on schedule |
| **WDT reset** | fault (the whole lane), soak | starved watchdog reset at **cycle 288,039** = 288.0 ms at 1 MIPS = exactly 18 ms × 16 with `PSA=1, PS=1:16` |
| Register reads at absolute addresses | fault, io, lockstep | `x gpio` / `x trisio` / `x wpu` / `x option_reg` / `x osccal` all resolved |
| Stimulus attachment by pin name | all libgpsim lanes | pin names are **`gpio0`..`gpio5`**, not `ra0`..`ra3` |

The WDT result deserves emphasis: gpsim's PIC12F675 watchdog model matches the
nominal datasheet period *exactly*, which is a better starting position than the
10F322, where `test/pic/test_fault_pic_core.h` already records that gpsim honors
`WDTCON.WDTPS` but does not match the datasheet and needs calibration.

`test/pic/gpsim_bootstrap.h` already anticipates the pin-name difference — it
defines `FOOTSW_PIN_NAME` defaulting to `"ra3"` and documents that "a part adapter
may override it". For this part it becomes `"gpio5"`. That override path exists
and has never been used; this would be its first consumer.

### 6.2 New infrastructure: calibration-word injection

As established in §4.5, an unmodified XC8 `.hex` **cannot run** on a simulated
PIC12F675 — the startup `call 0x3ff` walks off the end of flash and the part sits
in a watchdog reset loop. Every gpsim and libgpsim lane therefore needs the
oscillator calibration word injected first.

The mechanics are trivial (append one Intel-HEX data record placing `RETLW k` at
word address `0x3FF`, i.e. byte address `0x7FE`, and re-emit the EOF record), but
the *policy* is not, and it should be settled before any lane is written:

- **Which value?** It is factory trim, so any legal value simulates equally well.
  A fixed, documented constant makes the lanes deterministic. But it also means
  the simulator is running with a calibration the real device will not have — so
  a lane that ever asserts on absolute timing derived from the oscillator is
  asserting against a fiction. (This matters less than it sounds, because gpsim's
  clock is nominal anyway, but it should be stated rather than discovered.)
- **Where does injection live?** It must not mutate the shipping image. The
  natural shape is a derived `*_simcal.hex` produced into the build directory,
  which keeps the `test-*-expected-images` / release-provenance story clean —
  the SHA-256 baseline continues to cover the *shipping* HEX, and the injected
  one is a test artifact. This needs to be decided explicitly, because getting it
  wrong means either injecting into the released image or baselining an image
  that cannot run in any lane.
- **The `OSCCAL` guard interacts with it.** The §4.5 proposal snapshots `OSCCAL`
  at init and compares per tick. Under injection, that snapshot is the injected
  value — which is fine, and is in fact exactly what makes the guard testable:
  the fault harness can corrupt `OSCCAL` at `0x090` and require a reset.

### 6.3 Lanes that port for free

Because the modular architecture fits (§3), everything that verifies
`src/bypass_pure.c` covers this target with **zero** new work — there is no
equivalent of the PIC10F320's equivalence and lock-step-against-a-hand-inlined-copy
argument to construct, because there is no second expression of the algorithm:

- all host unit / property / exhaustive suites
- the KLEE symbolic lane
- the CBMC formal lane (`test/formal/test_cbmc.c`, `make test-cbmc`)
- `test/model_step.h` model convergence

Also free, or near-free:

- **`pic12f675-test-stack-bound`** — the current gate already handles polled and
  interrupt-root call graphs; only a Makefile lane and the `12f675.ini` path are
  needed for production images. Model B has historical 3/3/4 spike results
  (§3.1). Considering ISR first requires the separate retained spike measurement
  in §9, because no PIC12F675 ISR result survives from the original assessment.
- **`test-stack-bound-pic-regression`** — synthetic fixtures, part-independent,
  and already covering main-plus-interrupt-tree summing and XC8's real `i1_`
  duplicate naming. A new naming shape must add a fixture, but ISR support itself
  no longer needs one.
- **`pic12f675-coverage-check-fw`** — host gcov with an SFR mock. The mock header
  needs the new register set, but the lane's structure is unchanged.
- **`pic12f675-analyze-{cppcheck,misra}`** — platform and device-macro swap (§5).

### 6.4 Lanes that need a device-parameterization pass

This is the largest single chunk of work in the whole port, and it is test
infrastructure, not firmware.

The libgpsim harnesses are already split into thin per-part adapters
(`test/pic/test_io_pic.cc`, `test_lockstep_pic.cc`, `test_fault_pic.cc`) over
shared cores (`*_core.h`) — a structure built specifically so a second part could
slot in, and currently serving the 10F322 and 10F320. But the *cores* still
hard-code 10F32x register identity:

```c
/* test/pic/test_io_pic_core.h */
#define PORTA_ADDR  0x005u
#define TRISA_ADDR  0x006u
#define LATA_ADDR   0x007u
#define ANSELA_ADDR 0x008u
#define TRISA_INIT  0x08u

/* test/pic/test_fault_pic_core.h */
#define WPUA_ADDR   0x009u
#define OPTION_ADDR 0x00Eu
#define OSCCON_ADDR 0x010u
#define PR2_ADDR    0x012u
#define T2CON_ADDR  0x013u
#define WDTCON_ADDR 0x030u
```

Every one of those is wrong for the PIC12F675 (§2.1), and three of them —
`LATA`, `PR2`/`T2CON`, `WDTCON` — name registers that **do not exist** on this
part. Failure messages are register-named too ("TRISA did not remain exact…",
"physical PORTA output bits did not follow LATA").

The work is to lift register addresses, register *names*, expected init values,
and the injection matrix from core constants into adapter-supplied macros — the
same move already made once for `FOOTSW_PIN_NAME`, `PIC_FAULT_PROGRAM_WORDS`, <!-- name-contract: exempt (C adapter macro, not a Make variable) -->
`PIC_FAULT_EXPECTED_CHECKS` and `PIC_FAULT_EXTRA_OUTPUT_INJECTIONS()`. <!-- name-contract: exempt (C adapter macros, not Make variables) --> It is
mechanical but wide, and it touches lanes that currently pass for two parts, so
it wants to be a standalone, behaviour-preserving commit **before** any 12F675
adapter is written — with the 10F322 and 10F320 lanes green across it as the
proof.

Affected: `test_io_pic_core.h`, `test_fault_pic_core.h`, `test_lockstep_pic_core.h`,
and the `.stc` scripts (`footswitch_toggle.stc`, `power_on_pressed.stc`), which
carry `attach n1 fsw ra3` and cycle-count checkpoints derived from the 322's
2 MHz clock. The 12F675 runs at 4 MHz (1 MIPS vs 500 kIPS), so **every checkpoint
cycle number doubles** relative to the same wall-clock instant, on top of the
1.024 ms tick from §4.4.1. Note that `test-gpsim-wrappers` asserts the exact
string `attach n1 fsw ra3` in routed stimuli — that assertion becomes per-part.

### 6.5 Lanes that are new work, but structurally familiar

| Lane | Work |
|---|---|
| `pic12f675-test-config` | new decode table (§4.7); mechanism and HEX parser unchanged |
| `pic12f675-test-gpsim` | new `.stc` pair with re-derived cycle checkpoints; `gpio5` stimulus; calibration injection |
| `pic12f675-test-fault` | new injection matrix over the §4.8 guard set — including new cases for `CMCON`, `ADCON0`, `OSCCAL`, the `GPIO` shadow, and an `OPTION_REG` that now carries three guarded fields; new `PIC_FAULT_EXPECTED_CHECKS` count | <!-- name-contract: exempt (C adapter macro, not a Make variable) -->
| `pic12f675-test-io` | `GPIO`/`TRISIO` instead of `LATA`/`PORTA`/`TRISA`; note this lane gets *more* meaningful here, since shadow-vs-port divergence is observable |
| `pic12f675-test-lockstep` | `_ctx_` address extraction from the XC8 `.sym` is unchanged; adapter + proc name only |
| `pic12f675-test-soak` | re-derived timing budgets (§4.4.1); calibration injection |
| `pic12f675-test-target-variants` | fail-closed aggregate over one retained shipping/simcal matrix; its staged hash record becomes the qualified manifest only after compiler/injector reproducibility, every consumer re-verifies images and sidecars, and each target lane must emit one exact terminal device/lane/variant-bound result with its canonical nonzero check count and zero failures |
| `test-target-matrix`, `test-target-lane-markers` | extend to a third PIC chip |
| CI | one two-goal Make invocation in the shared `pic` job, mirrored in `scripts/ci-local.sh`, so pre-hardware and target evidence share one retained matrix; the device-header assert covers a third device out of the one DFP |
| Mutation | 13 entries in their own table with their own toolchain probe and sandbox validator; weighted toward the shadow, sub-tick, comparator, OSCCAL and ANSEL-mapping guards the 322 has no counterpart for |
| Build / budget | `build_pic12f675/`, `PIC12F675_FLASH_WORDS = 1024`, fake-XC8 `test-pic-build` producer plus private compiler/injector reproducibility and post-consumer hash probes |
| Release | image set, `MANIFEST.md`, provenance, `release/README.md` flashing notes (§8) |
| CI | new job or matrix entry; `test_ci_local_routing.sh` |
| Docs | `DESIGN_DOCUMENTATION.adoc`, `TOOLCHAIN.adoc`, `MISRA_COMPLIANCE.md`, `test/README.md` |

If the ISR model passes the §4.3 prerequisite, three of these change shape rather
than merely gaining a part:

| Lane | Additional work under the ISR model |
|---|---|
| `pic12f675-test-stack-bound` | regenerate every ISR variant, run the current gate, and retain each main tree, ISR tree including entry push, total used, reserve and spare (§4.3.2) |
| `pic12f675-test-fault` | two more guard cases (`GIE`, `T0IE`) plus the handshake-flag range check; injections now have an ISR that can run *between* injection and observation |
| `pic12f675-test-soak` | budgets stop needing the "actuation steals ticks" correction, because it stops being true (§4.3.1) — a simplification, but a re-derivation either way |

Also: sharing `volatile` state across an ISR boundary is new MISRA surface for
this project. The AVR shells already carry it, so precedent exists, but the PIC
suppression set in `test/misra_suppressions.txt` was written for a
single-threaded shell and would need a review pass rather than a copy.

---

## 7. Repository integration

Following the convention recorded for shell naming — family name where a shell
serves multiple parts, part name where the repository builds exactly one:

| Item | Name |
|---|---|
| Shell | `src/bypass_mcu_pic12f675.c` |
| Pin map | `src/bypass_pins_pic12f675.h` |
| Build macro | `BYPASS_MCU_PIC12F675` (new arm in `src/bypass_output_common.h`) |
| Build dir | `build_pic12f675/` |
| Image stem | `bypass-pic12f675-<variant>` |
| Implemented target families | build, analysis, coverage, stack, CONFIG, calibration, CLI gpsim, selected-variant libgpsim I/O, lock-step and fault, the long-duration soak, the pre-hardware and fail-closed target aggregates, guarded bench programming, and the mutation topology |
| Implemented integration | default `all`, both CI aggregates, canonical release images/soaks/evidence, tag-workflow rebuild and qualification, and generated release documentation |

**Name-length contract:** `bypass-pic12f675-cd4053_with_mute.hex` is 37
characters — **exactly** the current longest name
(`bypass-pic10f320-cd4053_with_mute.hex`), because `12f675` and `10f320` are the
same length. `test/test_makefile_name_contract.py` needs no change.

**A note on the PIC12F629.** It is the same die minus the ADC: same 1024 words,
same `STACKDEPTH=8`, same `CONFIG` at `0x2007`, same `GPIO`/`TRISIO`/`WPU`/
`OPTION_REG`/`CMCON`/`OSCCAL` at the same addresses — the *only* SFR difference is
that it has **no `ANSEL` and no `ADCON0`** (verified: zero occurrences of either
in `pic12f629.h`). gpsim supports `p12f629` too. So a family shell
(`bypass_mcu_pic12f6xx.c`, `BYPASS_MCU_PIC12F6XX`) guarding the `ANSEL`/`ADCON0`
writes and the corresponding two sanity checks behind one `#if` would cover both
parts for very little extra work — and the 629 is the cheaper, more available
part. The implementation selected a single-part `pic12f675` shell;
PIC12F629 family generalization remains deferred.

---

## 8. Open risks and unknowns

None blocks the Model B feasibility assessment; item 3 blocks selection of the
ISR model. The remaining silicon-only items (1, 2, 8, 9) are the port's slice of
the **`1.x.y` hardware-validation pass** — the pass *every* part in this
repository still awaits — and not `0.9.x` release blockers (see the v0.9.9 note
below). They are listed worst-first; item 9 was opened after this list was first
numbered and is appended rather than inserted, so that the cross-references to
these numbers elsewhere in the repository stay valid.

**Status 2026-08-13 (v0.9.9 disposition).** The project's version convention is
that `0.9.x` means "maximally validated in software" and `1.x.y` begins once a
design completes controlled hardware qualification — uniformly, for every part,
since none has such a record. Field-use reports exist for some other parts and
are not that; `HARDWARE_VALIDATION_LOG.md` states the difference and what a
controlled record must retain. Under that convention the PIC12F675 is
**release-supported from `v0.9.9`** on its software validation alone, exactly
like the other six parts, and the staging apparatus that had withheld it
(`RELEASE_STAGED_IMAGES`) is retired. Items 1, 2, 8 and 9 do not disappear; they
are reclassified as the same residual hardware risk every other part carries
un-enumerated, tracked for the `1.x.y` pass as `TODO.md` `T3-pic12f675-bench`.
The one non-negotiable that the software release still owes:
`release/README.md`'s flashing procedure MUST carry the OSCCAL/BG-preservation
requirement (items 1 and 2), because losing those
words yields a device that runs wrong while appearing to work — a hazard the
other parts do not have.

**Status 2026-08-13.** Items 4, 5, 6 and 7 are CLOSED. Items 4, 5 and 6 were
datasheet reads rather than bench work, and DS41190G answers them; item 4's own
stated assumption turned out to be wrong in the unsafe direction, and its
conclusion survives anyway. Item 7 closed on the shipping lane's own standing
evidence rather than on a document. Item 3 is Model-B-inapplicable.

That leaves items 1, 2, 8 and 9, and every one of them needs silicon — the same
four `TODO.md` tracks as `T3-pic12f675-bench`. Items 1 and 2 now have a
fail-closed baseline/write/readback workflow, but no real-hardware result has
been retained. Item 8 is established only as far as the pinned pack's parity
with the PIC10F322's hardware-tool set goes; neither programmer binary has ever
been run against this part. Item 9 was opened on 2026-08-11 in review of the port branch;
it also needs silicon, but a meter rather than a programmer. **What is left is a
bench**, tracked together with the graduation diff that follows it.

1. **Bandgap calibration bits in the CONFIG word (`BG<1:0>`).** These are
   factory-calibrated per device and set the BOD/POR trip voltages. XC8 emitted
   the erased `BG = 0b11` encoding in the measured CONFIG word (`0x31CC`), so the
   shipping image leaves the field outside its programmed intent rather than
   supplying a calibration value. Whether `pk2cmd` (PICkit 2) and `ipecmd`
   (PICkit 3/4/5) *preserve* the factory value on program is **untested here** and
   is a silicon-only failure mode — invisible to every simulator lane, which is
   exactly the class of defect `pic12f675-test-config` would exist to catch, and
   exactly the class it cannot catch alone. **Needs a datasheet read (DS41190) and
   a hardware-bench check.**
   *Status 2026-08-10: still open, now surfaced rather than silent.*
   `pic12f675-program` rebuilds the matrix, derives the selected image only from
   validated `VARIANT`, and decodes CONFIG from the private snapshot it passes to
   the programmer. The build-side half — that the toolchain leaves `BG<1:0>`
   erased rather than programming a value of its own over the factory one — is
   therefore enforced at flash time and not merely at build time. The guarded
   hardware workflow now measures the programmer's erase behaviour:
   `pic12f675-preflight` records CONFIG/BG and `pic12f675-program` requires the
   same BG value immediately before and after the write. The result is retained
   even when the comparison fails. No real result exists yet, so the item remains
   open.
2. **OSCCAL preservation on programming.** Same class, different register. A bulk
   erase that drops word `0x3FF` yields an untrimmed oscillator: wrong tick
   cadence, wrong `__delay_ms()` coil-pulse widths, and a device that still
   *appears* to work. `pk2cmd` has explicit OSCCAL handling for this family; that
   needs to be confirmed rather than assumed, and the result written into
   `release/README.md`'s flashing procedure. The §4.5 `OSCCAL` runtime guard does
   **not** help — it snapshots whatever is there at init, including garbage.
   *Status 2026-08-10: still open; one adjacent hazard closed.* The risk above
   is the programmer erasing the factory word. A second way to destroy it was
   introduced by this port itself — writing one of the DERIVED simulator images,
   which carries a fabricated calibration value — and `pic12f675-program` now
   refuses a selected snapshot that programs word 0x3FF. External image and
   whole-command substitution are unsupported; the private snapshot's SHA-256
   digest must remain unchanged through calibration and CONFIG checks before the
   target passes that same path to the programmer. Readback for the original
   risk is now enforced rather than printed: a pk2cmd baseline records the full
   `RETLW` word at 0x3FF, an immediate pre-write read must match it, and the
   post-write read/result must match too. Fake-tool regressions pin every branch;
   a retained result from real silicon is still required.
3. **The hardware return-stack bound under the ISR model — unquantified and
   blocking selection of that model.** It does not block Model B feasibility,
   but it is the one open item that could
   constrain the *firmware's structure* rather than a test. The bound becomes
   main's deepest chain + the ISR's deepest chain + 1, against 8 levels, against
   the project's 2-level reserve; the polled relay main tree measured 4. The
   current gate can compute the ISR bound, but no PIC12F675 ISR source, assembly
   or numeric result is retained, and XC8's prose annotation is not a substitute.
   **Getting a reproducible number is prerequisite work, not verification work.**
   If it does not fit, the ISR call graph has to be flattened or Model B chosen —
   a shell-design constraint discovered too late if measured after production
   implementation.
4. **Watchdog period characterization.** *CLOSED 2026-08-11 — read, assumption
   was wrong, conclusion holds.* DS41190G Table 12-4, parameter 31 `TWDT`,
   "Watchdog Timer Time-out Period (No Prescaler)": **min 10 ms, typ 17 ms,
   max 25 ms** at V<sub>DD</sub> = 5 V over −40 °C to +85 °C, and **max 30 ms**
   at extended temperature. Three findings, in the order they matter:

   - **The assumed spread was optimistic.** This item assumed the min/max spread
     was no worse than the 10F32x's −37%/+69% (DS40001585 param 31). Measured
     against the 17 ms typical it is **−41% / +47%**, and **+76%** at extended
     temperature: worse at *both* ends. The assumption, not the design, was the
     defect.
   - **The prescaler choice is unchanged.** The trigger written into this item
     was "if the fast end is materially worse than assumed, move 1:16 → 1:32".
     The fast end *is* worse, and 1:16 still stands by a wide margin: 10 ms × 16
     = **160 ms** floor against the shell's conservative 16 ms worst-case
     pet-to-pet bound, a factor of 10. Doubling to 1:32 would buy margin nothing
     needs and cost 320 ms of fault-detection latency.
   - **The shell already cites this correctly, nominal included.**
     `src/bypass_mcu_pic12f675.c` names "DS41190G Table 12-4 parameter 31 … a
     10ms unprescaled minimum, so the characterized minimum here is 160ms".
     That citation is exact, and so is its 18 ms nominal: §9.6.1 "WDT PERIOD"
     states "a nominal time-out period of 18 ms, (with no prescaler)", which is
     also the figure gpsim models. So 18 ms (prose nominal) and 17 ms
     (Table 12-4 characterized typical) are both DS41190G's; neither is loose,
     and nothing depends on either — see the note under the §4.4 table.
     **Do not "correct" the shell's 18 ms / 288 ms comments to 17 ms / 272 ms.**
     They cite the section that states 18 ms, they match what the simulator
     models, and the safety argument rests on the 160 ms floor either way.

   Residual: none for the period itself. The margin is now enforced at compile
   time on this part as on the PIC10F320: `bypass_pins_pic12f675.h` defines the
   de-rated `WDT_MIN_PERIOD_MS` (160 ms), `TICK_PERIOD_MS`, and the part's
   `WDT_LOOP_WORK_MS` / `WDT_ISR_STRETCH_PCT` terms, and the shared output
   drivers static_assert `WDT_PET_TO_PET_MAX_MS(pulse) < WDT_MIN_PERIOD_MS`
   against them -- the whole worst-case wall-clock pet-to-pet window, not the
   pulse alone -- so a future prescaler, tick, or pulse change that erodes the
   margin fails the build (v0.9.9 post-release polish; see CHANGELOG.md and
   "Watchdog Pet-to-Pet Budget" in DESIGN_DOCUMENTATION.adoc).
5. **Brown-out trip point.** *CLOSED 2026-08-11 — read; the expected limitation
   is confirmed, with numbers.* DS41190G Table 12-4, `BVDD` "Brown-out Detect
   Voltage": **2.025 V min, 2.175 V max** (no typical given; the hysteresis is
   listed TBD). Parameter 35 `TBOD` requires V<sub>DD</sub> to stay below `BVDD`
   for at least **100 µs** for the reset to be guaranteed, and that figure is
   characterized but not tested.

   So the detector trips at roughly 2.0–2.2 V, against peripherals that want
   >4 V — the CD4053 and the TQ2-L2-5V coil both. Between about 2.2 V and 4 V
   the firmware runs correctly and the peripherals may not, and no configuration
   choice available on this part changes that: unlike the PIC10F322 there is no
   `BORV` field, so there is not even a high/low selection to make. This is a
   **hardware-design constraint**, identical in kind to the one the 322
   documents: a builder who needs brown-out protection at the peripheral supply
   must provide it externally. Recorded so nobody reads `BOREN=ON` in the CONFIG
   word as the protection it is not.
6. **INTOSC accuracy over temperature and voltage.** *CLOSED 2026-08-11 — read;
   nothing in the timing budget is threatened.* DS41190G Table 12-2, "Precision
   Internal Oscillator Parameters", parameter F10 `FOSC`, "Internal Calibrated
   INTOSC Frequency", gives three graded tolerances:

   | Tolerance | Min / Typ / Max | Conditions |
   |---|---|---|
   | ±1% | 3.96 / 4.00 / 4.04 MHz | V<sub>DD</sub> = 3.5 V, 25 °C |
   | ±2% | 3.92 / 4.00 / 4.08 MHz | 2.5 V ≤ V<sub>DD</sub> ≤ 5.5 V, 0 °C ≤ T<sub>A</sub> ≤ +85 °C |
   | ±5% | 3.80 / 4.00 / 4.20 MHz | 2.0 V ≤ V<sub>DD</sub> ≤ 5.5 V, −40 °C ≤ T<sub>A</sub> ≤ +85 °C (IND) and −40 °C ≤ T<sub>A</sub> ≤ +125 °C (EXT) |

   **±5% is the figure to design against**, since a pedal is an
   industrial-temperature part in practice. Everything derived from the
   oscillator scales by it, and each consumer keeps its margin:

   - **Relay coil pulse.** 12 ms nominal becomes **11.4–12.6 ms**. The
     Panasonic TQ-L2-5V wants a 4 ms minimum set/reset pulse, so the 3× safety
     factor `src/bypass_output_tq2_l2_5v_relay.h` chose degrades to **2.85×**.
     Intact.
   - **Watchdog margin.** The earlier rough pulse-plus-tick estimate stretches
     with the oscillator (13.024 ms → **13.68 ms**); the watchdog runs on its own
     internal RC and does *not*, so the two errors do not correlate away. That
     physical estimate remains inside the shell's conservative 16 ms compile-time
     bound, which retains a factor of **10** against the 160 ms floor in item 4.
   - **Debounce.** Unaffected in the way that matters. The pure core counts
     samples, not milliseconds, so a ±5% oscillator moves the wall-clock
     debounce window by ±5% and changes no state-machine behaviour at all.

   The tolerance also bounds what any simulator lane can honestly claim about
   absolute timing: gpsim runs a nominal clock, so a lane asserting an absolute
   oscillator-derived figure is asserting against the *typical* device, never
   the worst-case one. The lanes assert relative cadences and bounded windows
   for this reason.
7. **`asynchronous_stimulus` initial state.** *CLOSED 2026-08-13 — the shipping
   lane asserts the disputed read head-on, and it holds.* In the spike, a
   stimulus declared `initial_state 1` read **low** on `gpio5` at a checkpoint
   before its first listed transition, while the same firmware with no stimulus
   attached read the pin high via the internal pull-up. The libgpsim harnesses
   drive via `set_Vth` with a low `Zth` (which the repository already documents
   as the correct mechanism, `putState` being a no-op for this purpose) and
   would not hit this — but the `.stc`-driven `pic12f675-test-gpsim` lane would.

   It does not, and the lane is arranged so that this is a *result* rather than
   an avoidance. `test/pic/pic12f675_footswitch_toggle.stc` declares
   `initial_state 1`, attaches the stimulus to `gpio5`, and then breaks at cycle
   **23040** — 2560 cycles **before** the stimulus' first listed transition at
   25600. That is precisely the window the spike observation describes. At that
   checkpoint `test/pic/run_gpsim_test.sh` asserts `GP5 == 1` outright, and the
   assertion passes on all three variants (`INIT: footswitch released (GP5=1)`).
   The checkpoint was not moved to dodge the condition; it sits inside it, on
   every run of a gated aggregate.

   What closes the item is therefore a standing check, not an explanation: the
   spike's tree was not retained, so the two configurations cannot be diffed and
   no root cause for the original reading is claimed here. The residual risk is
   bounded the right way round — if the behaviour ever appears, the failure is
   this `INIT_BYPASS` footswitch assertion going red in CI, not a silently
   relocated checkpoint. Anyone adding a `.stc` checkpoint ahead of a stimulus'
   first transition on this part should keep asserting the pin there for the
   same reason.
8. **Programmer device support.** PICkit 2 supports this family well. Whether the
   current `ipecmd` path still runs against PIC12F675 must be confirmed at the
   bench.
   *Status 2026-08-10: measured as far as this host allows; residually open.*
   The pinned device pack registers PIC12F675 with the same MPLAB hardware-tool
   set as the PIC10F322 this project already programs — an identical
   `hwtools/sdm` file list in the pack's `.pdsc`, and both parts named in every
   `sdm*.xml` that names either (§10 reproduces this). Since that pack is what
   supplies MPLAB X/IPE its device support, the part is still listed. What that
   does **not** establish is that `ipecmd` runs correctly against it: neither
   `pk2cmd` nor `ipecmd` is installed on any machine this repository is tested
   on, so the command shape is inherited from the working PIC10F322 target and
   has never been executed for this part. `pic12f675-program` was written on
   that basis, with `pk2cmd` as the default. Its ipecmd write path now requires
   a separate pk2cmd reader for the baseline and before/after trim comparison;
   no unconfirmed ipecmd read argv is claimed.
9. **GP2's readback margin against its Schmitt-Trigger input buffer.**
   *Opened 2026-08-11 in review of the port branch. Needs a meter, not a
   datasheet — the numbers below are already read.* The §4.2 port-follows-shadow
   comparison imports a DC precondition on the board, and it lands on exactly one
   pin. DS41190G Table 1-1 makes GP2 the only Schmitt-Trigger input among this
   design's outputs — V<sub>IH</sub> min **0.8·V<sub>DD</sub>** (D041), 4.0 V at
   a 5 V supply — where GP0, GP1, GP4 and GP5 are TTL at V<sub>IH</sub> min
   **2.0 V** (D040). The drive side is characterized at a single point: D090
   gives V<sub>OH</sub> min V<sub>DD</sub> − 0.7 V at I<sub>OH</sub> = −3.0 mA,
   V<sub>DD</sub> = 4.5 V — 3.8 V against a 3.6 V threshold, **0.2 V** of margin
   — and nothing is specified above 3 mA. `cd4053_with_mute` holds GP2 high in
   ENGAGED and `hw_output_state_intact()` re-reads it every 1.024 ms tick, so a
   pin driving its load *correctly* but landing between 2.0 V and
   0.8·V<sub>DD</sub> reads back low and the shell watchdog-resets permanently.
   It binds that one variant: `cd4053_simple` leaves GP2 a spare driven low, and
   `tq2_l2_5v_relay` raises it only inside the blocking coil pulse, which no
   integrity check straddles.

   **The reference design is not at risk.** On the CD4053 board GP2 drives a
   MOSFET gate; on the TMUX4053 board it drives a CMOS control input. Either
   way the only real resistive load is the 100 kΩ fail-safe pulldown both boards
   fit — 50 µA at 5 V, roughly 60× inside the one point D090 characterizes. The
   item is open because that margin rests on a *board* choice rather than on
   anything this repository builds or tests, and this part has no bench
   validation underneath it. It is the same class as items 1 and 2 — invisible
   to every simulator lane, since gpsim models pins ideally.
   The mutation lane's "shadow never reaches the port" mutant (deleting
   `GPIO = gpio_shadow_` from `hw_pin_set_high`) proves the guard fires and
   resets when the port diverges from the shadow; nothing in the repository can
   exercise the board condition under which it would fire *spuriously*.

   **Bench check:** on the `cd4053_with_mute` variant with the real load
   attached, engage the effect and measure GP2 against V<sub>DD</sub>; confirm
   the level exceeds 0.8·V<sub>DD</sub> and record the margin. Do it on
   whichever of the two board options is built, since they load the pin
   differently. The recorded margin is what bounds the minimum pulldown a
   builder may substitute. The requirement is stated in
   `src/bypass_pins_pic12f675.h` alongside the GP3 and GP4 pin policies.

### Audited and found sound: the nominal-path firmware argument

The v0.9.9 second-pass review found **no nominal-path PIC12F675 firmware
defect**. For a reference-grade artifact that verdict is only as good as the
reasoning behind it, so the defense-in-depth chain that backs it is recorded
here rather than left implicit. Corruption of the persisted context is caught
before it can drive a wrong output:

- **`program_state`** is rejected two independent ways. `debounce_step()`'s
  `default:` arm returns `res.fault = true` -- commented "should be impossible
  (but let caller know)" in `src/bypass_pure.c` -- and the shell's per-tick
  sanity gate independently rejects `program_state > RELEASE_DEBOUNCE_WAIT`
  (`src/bypass_mcu_pic12f675.c`).
- **`effect_state`** is rejected by the fail-closed `else` arm of
  `hw_is_sanity_check_failed()`, which treats any value that is neither
  `BYPASS` nor `ENGAGED` as a failure ("invalid logical state fails closed",
  `src/bypass_output_*.c`), backed by the shell gate's `effect_state > ENGAGED`
  term.
- **Single-byte shell guards fail safe.** Every range and intactness term in
  that gate -- `debounce_counter > RELEASE_THRESH`, footswitch pull-up intact,
  output-latch intact, critical SFRs intact -- funnels to
  `hw_force_wdt_reset()`, so a corrupted control byte forces a clean recovery
  reset rather than an acted-upon wrong state.
- **The nominal blocking relay coil pulse ends by commanding both coils low.** Both
  `hw_set_bypass_state()` and `hw_set_engaged_state()` call
  `set_relay_coils_low()` after the `BYPASS_DELAY_MS` pulse. Settled operation is
  covered by the per-tick sanity gate, which escalates an energized coil to a
  fail-safe recovery (`docs/relay_coil_fault_correction.md`); no gate runs during
  the delay (`src/bypass_output_tq2_l2_5v_relay.c`). A coil-state upset during
  that pulse can alter the intended or inactive coil until the post-pulse clear
  and may affect the mechanical relay.

The one nominal-path case those range and actuation guards do **not** cover is
an *in-range* single-bit upset of `debounce_counter` -- a flip that stays
within `[0, RELEASE_THRESH]` yet crosses `PRESSED_THRESH`, fabricating a
phantom toggle with no footswitch press. On the current v0.9.10 PIC12F675
build that case is closed, not open: `PIC12F675_CFLAGS` defines
`-DBYPASS_CTX_CHECK`, so the gate's first term compares a persisted-context
snapshot against `debounce_ctx_check_word()`. The shell then computes and
publishes only from the
validated snapshot, so a single-bit upset confined to persisted `ctx_` or
`ctx_check_` is detected, safely overwritten, or left mismatched for the next
check instead of being consumed and re-folded (see
`docs/context_seu_detection.md`). This bounded guarantee excludes locals,
registers, code and control flow. Before the F2/F3 additions, XC8 resource
checks, target simulation, and the then-current 132-mutant gate passed. The
merged physical-pin target/resource evidence and complete 137-mutant run remain
pending, as does the shared `1.x.y` silicon-validation pass.

**Why the ported tests are trusted to be distinct.** Porting the PIC10F322
lanes to the PIC12F675 carries a copy-paste risk: a lane that still compiled
but no longer exercised part-specific behavior would pass vacuously. The
mutation design addresses that risk, with its final merged run still pending.
The PIC12F675 target-tool lane contributes
23 mutants (per the step-10 status in §9), while the F2 transaction seam, the
relay shadow-clear ordering and the relay escalation's parked-GP4
canonicalization each add a PIC12F675 shell mutant to the
host-available core table. The repository mutation
inventory is **137**, weighted toward the `GPIO` shadow, sub-tick timing,
comparator/`CMCON`, `OSCCAL` and ANSEL-mapping guards the PIC10F322 has no
counterpart for (§6.5). Each of the 23 target-tool mutants carries its own
toolchain probe, named behavioral signature and sandbox validator. A complete
run requires every mutant to be killed, so a copy-paste port that did not
actually drive 12F675-specific behavior could not stay green.

---

## 9. Historical effort and suggested sequencing

The 2026-08-05 assessment proposed the order below so each step would be
independently green and independently revertible. It is retained as implementation
history, not as a list of currently absent features.

**Implementation sequencing note (2026-08-10).** Work spanning steps 2 through 7
landed together in `64b4d2d`, so that implementation commit does not satisfy the
independent-reversion requirement above. The review branch had already been
published and accumulated dependent commits and merges before this was caught;
splitting it afterward would invalidate those reviewed hashes and their evidence.
The sequencing requirement is therefore waived for that implementation commit
only. Its commit message retains the per-gate commands, results and negative
probes, while the subsequent isolation, target-I/O, lock-step, coverage, gpsim,
fault, matrix, clean-contract, spare-pin and rationale commits retain focused
review and verification evidence. The original sequencing rule remains useful
review history; the only unfinished work in this section is the `1.x.y` hardware
bench identified in §8.

**Current implementation status (v0.9.10):** step 0 selected the 1.024 ms TMR0 design,
a single-part PIC12F675 shell, and Model B. Step 1 is not applicable unless the
ISR alternative is reconsidered; steps 2 through 9 are implemented — step 9
re-derived the holds through the tick period rather than letting the slack absorb
the 1.024 ms stretch (§4.4.1). Step 10 is done: `pic12f675-test` and
`pic12f675-test-target{,-variants}` are implemented and carry the third leg of
`test-target-matrix` and `test-target-lane-markers`; 23 target-tool mutants with
their own toolchain probe, named behavioral signatures and sandbox validator,
plus three host-available shell mutants, contribute to a combined mutation
inventory of 137 after the F2, F3 and B1 additions;
and both aggregates now run in CI's shared `pic` job with the two mirrors —
`scripts/ci-local.sh` and `test-ci-local-routing` — extended alongside. Step 10
is complete. Step 11 is done (v0.9.9): the user-facing documentation landed;
`pic12f675-program` exists with a pre-flash gate that refuses any image carrying
a calibration word, and `pic12f675-preflight` plus mandatory immediate
before/after reads retain the evidence needed to measure §8 items 1 and 2
(items 1, 2 and 8 state what this still does not close on this host). Release
integration is now **complete**, not deferred: the three shipped HEXes are in
`RELEASE_IMAGES` (18 → 21) and `RELEASE_IMAGE_DIRS`, the three soak combinations
are in `RELEASE_SOAK_NAMES` (15 → 18), the build and both aggregate logs are in
the retained-evidence inventory (28 → 34), `scripts/make-release.sh` carries a
full PIC12F675 arm (preflight assertions, build, both qualification gates, a
soak loop over the DERIVED simcal image, and a manifest arm), and
`.github/workflows/release.yml` rebuilds the part and re-runs its lanes on the
pinned runner. The staging apparatus (`RELEASE_STAGED_IMAGES` and its parse-time
disjoint guard) is retired; `test-release-images` still cross-checks the manifest
arms against the canonical set in both directions, so a future part added without
its arm fails the release. The datasheet half of §8 is closed too (items 4, 5
and 6, read 2026-08-11). What remains is the `1.x.y` hardware bench (items 1, 2,
8, 9), which does not block the `0.9.x` release. The table retains the original
dependency order rather than claiming every row is open.

| # | Step | Notes |
|---|---|---|
| 0 | **Decide two forks and identify the concurrency candidate:** §4.4.1 (1.024 ms TMR0 vs exact 1 ms TMR1), §7 (single-part `pic12f675` vs `pic12f6xx` family shell covering the 629), and whether ISR merits the step-1 spike | Do not select ISR from the flash table; its decision follows the stack result |
| 1 | **If ISR is being considered:** regenerate all three ISR spikes, run the current `check_stack_depth_pic.sh`, retain the complete inputs/output, then choose ISR or Model B | **Decision prerequisite, not production verification** (§8 item 3). If the bound does not fit with reserve, flatten and remeasure or choose Model B before the shell is written |
| 2 | Device-parameterize `test_{io,fault,lockstep}_pic_core.h` | Behaviour-preserving; 322 + 320 lanes green across it is the acceptance test. **Largest single item** |
| 3 | Calibration-word injection helper + policy (§6.2) | Standalone, testable on its own |
| 4 | Pin map, `bypass_output_common.h` arm, shell, build lane + flash budget | Firmware — user-authored |
| 5 | `pic12f675-test-stack-bound`, `-analyze`, `-coverage-check-fw` | Stack lane wires the current gate to production images; under ISR its expected shape comes from the retained step-1 result |
| 6 | `pic12f675-test-config` (new decode table) | |
| 7 | `.stc` pair + `pic12f675-test-gpsim` | First lane needing re-derived cycle checkpoints |
| 8 | libgpsim adapters: io, lockstep, fault | Rides on step 2 |
| 9 | Soak + re-derived timing budgets | Rides on §4.4.1; simpler under the ISR model (§4.3.1) |
| 10 | Aggregates, mutation topology, CI routing | |
| 11 | Docs, release integration, hardware bench (§8 items 1, 2, 8, 9) | Docs and v0.9.9 release integration are complete; the four §8 risks remain for the `1.x.y` hardware pass |

The historical estimate assigned roughly a day to firmware design and
implementation, with test infrastructure expected to dominate the calendar and
step 2 expected to gate most of it.

**Why step 1 sits where it does.** Every other test item can be built after the
shell and fixed independently of it. The return-stack bound cannot: it is a
property of the shell's call graph and is silent when violated on this core. The
current gate can measure it, but the original throwaway ISR spike and result were
not retained. Discovering after implementation that the ISR graph does not fit
means rewriting the shell, not adjusting a test. Under Model B this step does not
exist at all.

---

## 10. Reproduce these numbers

From the repository root. The spike shell referenced below is not in the tree —
what is reproducible without it is the toolchain support, the device facts and
the simulator's processor/pin support. The flash figures and functional/timing
simulation results require the missing shell and built image.

```sh
XC8=/opt/microchip/xc8/v3.10/bin/xc8-cc
DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8

# XC8 targets the part with the already-pinned pack (prints "12F675:400:2";
# XC8 v3.10 also emits a benign "(2044) unrecognized option" warning here):
"$XC8" -mcpu=12F675 -mdfp="$DFP" --chipinfo | grep '^12F675'

# Device facts (flash words, stack depth, CONFIG address):
grep -E '^(ARCH|ROMSIZE|STACKDEPTH|CONFIG)' "$DFP"/pic/dat/ini/12f675.ini

# The oscillator calibration zone at word 0x3FF:
grep -o '<edc:CalDataZone[^>]*>' \
  /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/edc/PIC12F675.PIC

# WPU has no bit 3 -- GP3 has no weak pull-up:
grep -oE '_WPU_WPU[0-9]_POSN' "$DFP"/pic/include/proc/pic12f675.h | sort -u

# No LATx, no TMR2/PR2/T2CON, no OSCCON, no WDTCON on this part:
grep -E 'extern volatile unsigned char.*__at' "$DFP"/pic/include/proc/pic12f675.h \
  | sed 's/.*char *//'

# gpsim supports the part (and the PIC12F629):
printf 'processor list\nquit\n' | gpsim -i 2>/dev/null | grep -E '12f6(29|75)'

# gpsim pin names are gpio0..gpio5, not ra0..ra3:
strings /lib/libgpsim.so.0 | grep -xE 'gpio[0-5]' | sort -u

# cppcheck has the classic mid-range platform alongside the enhanced one
# (a bad --platform name is a hard error, so a clean run is the check):
printf 'int main(void){return 0;}' > /tmp/p.c
cppcheck --platform=pic8 --quiet /tmp/p.c && echo 'pic8 ok'
cppcheck --platform=pic8-enhanced --quiet /tmp/p.c && echo 'pic8-enhanced ok'
rm -f /tmp/p.c

# The package pinout, from the pack rather than a web summary:
python3 -c "import re,sys; s=open('/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/edc/PIC12F675.PIC',encoding='utf-8',errors='replace').read(); [print(i,'/'.join(re.findall(r'edc:name=\"([^\"]+)\"',b))) for i,b in enumerate(re.findall(r'<edc:Pin>(.*?)</edc:Pin>',s,re.S),1)]"

# Hardware-tool support parity with the PIC10F322, quoted in section 8 item 8 --
# the pack's per-device hwtool file list, and the per-tool device lists:
for p in PIC12F675 PIC10F322; do
  printf '%s: ' "$p"
  awk -v d="<device Dname=\"$p\">" '$0 ~ d,/<\/device>/' \
    "$DFP"/../Microchip.PIC10-12Fxxx_DFP.pdsc \
    | sed -n 's@.*hwtools/\([^"]*\)".*@\1@p' | tr '\n' ' '; echo
done
for f in "$DFP"/../hwtools/sdm/*.xml; do
  printf '%-22s 12F675=%s 10F322=%s\n' "$(basename "$f")" \
    "$(grep -c PIC12F675 "$f")" "$(grep -c PIC10F322 "$f")"
done

# The 10F322 scale reference quoted in section 3 (473 of 512 words):
"$XC8" -mcpu=10F322 -mdfp="$DFP" -std=c99 -O2 \
  -D_XTAL_FREQ=2000000 -DBYPASS_MCU_PIC10F322 -DTQ2_L2_5V_RELAY -Isrc \
  -o /tmp/fw322.elf \
  src/bypass_mcu_pic10f322.c src/bypass_pure.c src/bypass_output_tq2_l2_5v_relay.c
```

The flash figures in §3 were produced by compiling `src/bypass_pure.c` and
`src/bypass_output_<variant>.c` unmodified, together with the spike shell and a
spike `bypass_pins_pic12f675.h`, as:

```sh
"$XC8" -mcpu=12F675 -mdfp="$DFP" -std=c99 -O2 \
  -D_XTAL_FREQ=4000000 -DBYPASS_MCU_PIC12F675 -D<VARIANT_MACRO> \
  -I<spike-dir> -Isrc -o fw.elf \
  <spike-dir>/shell.c src/bypass_pure.c src/bypass_output_<variant>.c
```

The historical Model B stack-depth result in §3.1 was produced by running the
then-current repository gate against the assembly XC8 emitted for those builds:

```sh
./test/check_stack_depth_pic.sh <spike-dir>/fw_<variant>.s \
  "$DFP"/pic/dat/ini/12f675.ini 2 "PIC12F675 <variant>"
```

The §4.3 ISR figures came from two further spikes. The PIC12F675 one is the
shell above with the polled tick wait replaced by a TMR0 ISR plus the AVR's
`timer_isr_called_` handshake. **The PIC10F322 one is the shipping shell itself**
— `src/bypass_mcu_pic10f322.c`, copied out of the tree and given the same five
edits, so the +38-word delta is measured against real code rather than against
another spike:

1. `static debounce_context_t ctx_;` → `volatile`, plus a
   `volatile uint8_t timer_isr_called_;`
2. a `void __interrupt() isr(void)` that clears `TMR2IF`, sets the handshake, and
   runs `debounce_integrate()`
3. `hw_tick_timer_start()` also sets `PIE1bits.TMR2IE`, `INTCONbits.PEIE`,
   `INTCONbits.GIE`
4. the main loop's `hw_wait_for_tick()` poll and inline `debounce_integrate()`
   replaced by the handshake protocol
5. the sanity gate gains the handshake range check, for AVR parity

Both were built exactly as their polled counterparts above. At the time, running
the gate against the *ISR* assembly produced the historical `i1_` parser failure
quoted in §4.3.2:

```sh
./test/check_stack_depth_pic.sh <spike-dir>/isr_<variant>.s \
  "$DFP"/pic/dat/ini/12f675.ini 2 "PIC12F675-ISR <variant>"
```

That command would produce a numeric main-plus-ISR verdict with the current
gate, but the spike source and generated assembly were not retained, so it cannot
be rerun now. A new result must retain a complete source snapshot or patch, exact
XC8/DFP command, all three generated assemblies (or immutable hashes), and the
complete gate output; the old parser failure is not stack evidence.

---

## 11. Historical documentation plan

The 2026-08-05 assessment expected the port to produce or amend the documents
below, mirroring the structure established by the PIC10F320 work. The table is
retained as planning history; the current support disposition is stated at the
top of this document.

| Topic | Document |
|---|---|
| This assessment | `docs/pic12f675_feasibility.md` (here) |
| Integration decisions, increment by increment | a `docs/pic12f675_*.md` plan, if the port is staged like the AVR-XT one |
| Pin map, CONFIG word, clock/timer/WDT, resource use | `DESIGN_DOCUMENTATION.adoc` |
| Toolchain versions, build commands, flash budget | `TOOLCHAIN.adoc` |
| Per-lane rationale, simulator gaps, timing budgets | `test/README.md` |
| Flashing — including the §8 OSCCAL and bandgap procedures | `release/README.md` |
| MISRA status and any new deviations | `MISRA_COMPLIANCE.md` |

The PIC10F322 linker finding in §4.3 and the later PIC10F322 return-stack
measurement produced two corrections to its existing design notes. Both have
now been applied, independent of whether this port happens:

| Document | Correction |
|---|---|
| `docs/phase2_pic_shell.md` §6 | Protection is now required only for a future multi-byte shared object; the documented single-byte option preserves the AVR's lock-free protocol without `-fshort-enums` (§4.3.2 item 1). |
| `docs/phase2_pic_shell.md` §1 | The original three reasons remain historical rationale; a separate later retention reason now records the relay ISR link failure, inferred flash occupancy and measured return-stack limit (`non-blocking_output_schemes_feasibility.md` §§2.2–2.4). |
