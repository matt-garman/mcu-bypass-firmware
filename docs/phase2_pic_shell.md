# PIC10F322 hardware shell — design notes

Reference notes for `src/bypass_mcu_pic10f322.c`: the datasheet facts it was
built from, the locked design decisions behind its tick/watchdog model, and the
rationale that is not obvious from reading the code. The shipped source is
always the authority on *what* the shell does; this file records *why*.

Scope note: these notes describe the **PIC10F322** shell only. The PIC10F320 is
a separate, deliberately different implementation — its 256-word flash cannot
hold the modular architecture, so its logic is inlined into `main()`. See
`pic10f320_feasibility.md` for the measurements, `pic10f320_special_case.md` for
its assurance argument and support contract, and `pic10f320_validation.md` for
what was run and what it returned. `pic10f320_merge_plan.md` records how that
target was integrated, but it is a historical decision record — do not read it
for current status.

The general architecture argument — why the algorithm is shared but the main
loop is not — lives in `DESIGN_DOCUMENTATION.adoc`, "Multi-MCU Architecture".

---

## 1. Locked decision: tick/WDT model "B"

**Model B = polled hardware timer + pure fault watchdog.** TMR2 drives the
~1 ms tick, *polled* in the main loop (no sleep); the watchdog is a pure fault
watchdog at a much longer period, `CLRWDT`'d once per tick.

The alternative considered was a WDT-periodic-wakeup loop (sleep, wake on WDT,
sample, update, sleep). Model B was chosen for three reasons:

1. **It matches the AVR design more closely** and is simpler to reason about —
   the same 1 ms sampling cadence, just polled instead of interrupt-driven.
2. **It dissolves the blocking-actuation conflict.** With the WDT at ~256 ms and
   the worst-case awake burst ≈ 13–14 ms (1 ms tick wait + the 12 ms relay/mute
   pulse + overhead), a blocking actuation fits comfortably inside one WDT
   period. So the output drivers keep their plain `__delay_ms()` — no
   WDT-aware delay abstraction is needed.
3. **It dissolves the shared-state hazard** — see §6.

Accepted trade-off: no low-power sleep. Fine for an always-powered pedal.

**Consequence to remember:** because the loop is polled and the actuation
blocks, the PIC shell *stops sampling the footswitch* for the duration of a
relay/mute pulse, where the AVR shell keeps sampling inside its ISR. §5 covers
why that is safe. It also means anything that counts ticks must account for
actuation stealing them.

---

## 2. Datasheet facts (PIC10(L)F320/322, DS40001585)

Confirmed against the datasheet and the DFP device header
(`<DFP>/xc8/pic/include/proc/pic10f322.h`), which is authoritative for register
and CONFIG names. SFR addresses in parentheses.

- **GPIO — only 4 I/O.** `RA0`, `RA1`, `RA2` are bidirectional (and
  analog-capable); **`RA3` is input-only** (shared MCLR/VPP). Registers:
  `PORTA`(0x05), `TRISA`(0x06, 1 = input), `LATA`(0x07, output latch — write
  through this), `ANSELA`(0x08, 1 = analog; **must be cleared for digital
  I/O** — pins power up analog), `WPUA`(0x09, per-pin weak pull-up), and
  **`OPTION_REG`(0x0E)`.nWPUEN` (bit 7, active-low — *clear* to enable the weak
  pull-ups)**.
- **Timer2** (1 ms tick source): `T2CON`(0x13: `T2CKPS` prescale,
  `T2OUTPS` postscale, `TMR2ON`), `PR2`(0x12), `TMR2`(0x11), flag
  **`TMR2IF` = `PIR1`(0x0C) bit 1**. As built at `FOSC` = 2 MHz:
  FOSC/4 = 500 kHz, prescale 1:4 (`T2CKPS` = `0b01`) → 125 kHz,
  `PR2` = 124 → 125 counts = 1 ms. Postscale 1:1 so `TMR2IF` sets every
  period; the loop polls and clears it.

  > **Datasheet erratum worth knowing:** the TMR2 prescale field is a 2-bit code
  > `00/01/10/11` = 1:1/1:4/1:16/1:64. The datasheet *prose* is incomplete on
  > this point; the register table is authoritative.

- **WDT** (fault watchdog): time base = 31 kHz LFINTOSC, independent of `FOSC`.
  `WDTCON`(0x30) = `SWDTEN`(bit 0) + `WDTPS<4:0>`(bits 1–5). ~256 ms ≈
  `WDTPS` = `0b01000` (1:8192), mirroring the AVR's 250 ms. Datasheet-confirmed:
  LFINTOSC = 31 kHz **±25%** (OS09) and the WDT period is characterized at
  **−37%/+69%** (param 31), so worst-case ~160 ms still spans the ~14 ms awake
  burst with comfortable margin. (An earlier ~32 ms choice gave only ~1.4× and
  was lengthened for exactly this reason.) An awake WDT timeout is a device
  reset — the fault-recovery path we want.
- **Oscillator:** internal HFINTOSC, frequency via `OSCCON`(0x10) `IRCF<2:0>`.
  As built: **2 MHz = `0b100`**, selected over 16 MHz for lower current draw.
  `FOSC` CONFIG bit = INTOSC. `IRCF` is the only read/write field in `OSCCON`
  on this part, which is why validating it covers the register's whole
  timing-relevant state.
- **CONFIG (`#pragma config`)** bits available: `FOSC`, `BOREN`, `WDTE`,
  `PWRTE`, `MCLRE`, `CP`, `LVP`, `LPBOR`, `BORV`, `WRT`. The as-built selections
  and their rationale are documented in the shell's own header comment; the
  emitted CONFIG word is `0x389E` and is verified out of the built HEX by
  `make pic10f322-test-config`.

---

## 3. Pin map

Only 4 pins, so the footswitch (an input) goes on the input-only RA3
(`MCLRE = OFF`), freeing the three bidirectional pins for outputs. Bit positions
are PORTA bit indices.

| Logical pin            | PIC bit | AVR bit (for contrast) |
|------------------------|---------|------------------------|
| `FOOTSW_PIN` (input)   | RA3 = 3 | PB0 = 0                |
| `LED_PIN`              | RA0 = 0 | PB1 = 1                |
| `CD4053_PIN` (simple)  | RA1 = 1 | PB2 = 2                |
| `RELAY_RESET_PIN`      | RA1 = 1 | PB2 = 2                |
| `RELAY_SET_PIN`        | RA2 = 2 | PB3 = 3                |
| `CD4053_CTL1` (mute)   | RA1 = 1 | PB2 = 2                |
| `CD4053_CTL2` (mute)   | RA2 = 2 | PB3 = 3                |
| output mask (all vars) | `0x07` (RA0–RA2) | `0x1E` (PB1–PB4) |

The bit positions differ from AVR for *every* logical pin — which is why pin
assignments live in a per-MCU pin map (`src/bypass_pins_pic10f322.h`) rather
than in the drivers. The relay and mute variants use all three output pins
(zero spare); cd4053-simple leaves RA2 as a spare driven low, which the
integrity checks still cover (see §4).

---

## 4. How the shell implements the hardware contract

Only the GPIO-leaf ops and the output-driver ops are declared in the shared
`bypass_hw_iface.h`. The footswitch / WDT / tick / `mcu_init` rows below are
**shell-internal** `static` functions, not part of the shared header — MISRA
Rule 8.7, since each is referenced only within this translation unit.

| Operation | PIC implementation |
|---|---|
| `hw_pin_set_high/low(pin)` | set/clear the `LATA` bit |
| `hw_led_pin_set_high/low` | `LATA` LED bit |
| `hw_configure_output_pins(m)` | `ANSELA &= ~m` (digital); `TRISA = ~m & 0x0F` (outputs); `LATA &= ~m` (low) |
| `hw_output_state_intact(required, expected_high)` | **exact** `TRISA` match against the configured direction state, *plus* the required pins still outputs, *plus* the full `LATA` output latch matching `expected_high` |
| `hw_read_footswitch` (static) | read the `PORTA` RA3 bit |
| `hw_critical_sfrs_intact` (static) | `OSCCON.IRCF`, `WDTCON.WDTPS`, `PR2`, `T2CON`, `ANSELA` on the output pins, the `WPUA` latch state, and the global `OPTION_REG.nWPUEN` |
| `hw_wdt_pet` (static) | `CLRWDT()` |
| `hw_wait_for_tick` (static) | spin until `TMR2IF`, then clear it |
| `hw_tick_timer_start` (static) | `PR2` + `T2CON`; no interrupt (polled) |
| `hw_mcu_init` (static) | `OSCCON.IRCF` = 2 MHz; `ANSELA = 0`; footswitch `WPUA` + `OPTION_REG.nWPUEN`; `WDTCON.WDTPS` |
| `hw_force_wdt_reset` (static) | spin with the WDT un-petted → device reset |
| driver `hw_set_*` / sanity / `hw_init_output_pins` | shared drivers, unchanged; pins come from the pin map |

Two integrity checks deserve emphasis because they are stronger than the
obvious version:

- **`hw_output_state_intact` compares the complete implemented `TRISA` state,
  not just the caller-required pins.** A subset check misses a direction flip on
  a *spare* output — on cd4053-simple, RA2 is driven low and is not in the
  required mask, so a `TRISA` upset would float it invisibly. The latch half is
  equally deliberate: `LATA` still reads the correct value when a pin has been
  flipped to an input, so direction and latch must both be checked.
- **The pull-up check covers both halves of a two-part enable.** The weak
  pull-up needs the per-pin `WPUA` latch *and* the global, active-low
  `OPTION_REG.nWPUEN`. An upset of either silently disables the pull-up and
  floats the footswitch, so both are validated. (The AVR analogue checks the
  single `PORTB` latch, because there is only one thing to check.)

The main loop, conceptually parallel to the AVR's but with no ISR and no
`timer_isr_called_` handshake — the single polled loop reaching `CLRWDT` is the
liveness proof:

```
init():  CONFIG bits via #pragma; hw_init_output_pins(); hw_mcu_init();
         hw_set_bypass_state(); ctx = debounce_init_context(hw_read_footswitch());
         hw_tick_timer_start();
loop:    hw_wait_for_tick();                     // poll TMR2IF (~1 ms)
         if (sanity fails) hw_force_wdt_reset();
         ctx.debounce_counter = debounce_integrate(hw_read_footswitch(), ctx.debounce_counter);
         apply debounce_step(ctx) -> outputs on toggle / fault -> reset
         hw_wdt_pet();                           // CLRWDT
```

---

## 5. Behavioural divergence from the AVR shell

On AVR the footswitch is sampled by the Timer0 ISR even *during* the 12 ms
actuation; on PIC the single polled loop pauses sampling for those ~12 ms.

This is benign, and the argument is specific rather than hand-waved: the
actuation only ever runs immediately after a toggle, at which point
`debounce_step` has already reloaded the counter to `RELEASE_THRESH`, so the
firmware is in the post-toggle lockout window. The switch is still held. Re-arm
requires `RELEASE_THRESH` *release* samples, which cannot begin until the user
releases — well after the actuation has finished. Missing samples inside a
window where every sample would have been "still pressed" changes nothing.

The practical consequence is for *tests*, not for the firmware: any PIC timing
test that counts ticks must budget for the actuation stealing them, or it will
mis-measure the release gate.

### 6. Concurrency model: single-threaded, so no atomicity requirement

The AVR shell relies on `-fshort-enums` partly for **atomicity**: it samples the
footswitch in the Timer0 ISR and shares `timer_isr_called_` and `ctx_` across the
ISR/`main()` boundary, so those individual shared fields must be 8-bit to be read
and written in a single uninterruptible instruction on the 8-bit AVR.

Model B on the PIC has **no such requirement, because it has no second thread.**
It *polls* `TMR2IF` in the main loop — there is no timer ISR, no
`timer_isr_called_`, and `ctx_` is owned solely by `main()`.
`debounce_integrate()` runs inline in the polled loop, not asynchronously. One
execution context means nothing is shared, which means no atomic-access
requirement. This is the third payoff of Model B, alongside the
blocking-actuation and WDT resolutions in §1, and it is why XC8's lack of
`-fshort-enums` (it sizes enums as `int`) is harmless here.

For the record, and for anyone tempted to add an ISR later: the PIC10F322 is an
8-bit core and does **not** provide atomic multi-byte access. A 16-bit `int` — or
the multi-byte `debounce_context_t` — compiles to several instructions and is
interruptible mid-operation. So *if* a future revision ever added an ISR sharing
a multi-byte object with `main()`, that change must add explicit protection
(disable interrupts around the access, or share only a single byte). Note that
an 8-bit enum would not make a multi-field struct atomic regardless. No such
sharing exists today.

> Related XC8 gotcha, learned the hard way: never take `sizeof` of a struct of
> enums on this target as a proxy for what the code generator allocated, and
> never `const`-qualify a local that holds an SFR read — XC8 places `const`
> objects in program flash and rejects their runtime initializers.

---

## 7. How this shell is validated

`bypass_pure.c` is unchanged and MCU-neutral, so the host and formal suites
(golden model, CBMC, model check, KLEE) **already cover the algorithm** for the
PIC target. This shell is validated separately by static analysis and MISRA, the
CONFIG-word check against the built HEX, gpsim register-level scripts, libgpsim
fault injection, built-HEX/model lock-step, target-I/O timing checks, a soak
lane, and mutation testing.

`test/README.md` is the authority on what each of those layers asserts and how
to run them; the Makefile's `pic-*` targets are the entry points. The AVR
Classic shell remains the reference implementation with the longest validation
history.
