# PIC Phase 2 — PIC10F32x hardware shell

Status: **implemented (pre-hardware)** on branch `pic10f32x_support` — increments
2a–2d are all done (2a+2b committed; 2c+2d on the branch). What remains is real
PIC10F322 hardware bring-up. Phase 1 (the hardware-
abstraction refactor) is complete; this phase adds a second implementation of the
`bypass_hw_iface.h` contract for the PIC10F320/322, plus that family's own
`main()` and CONFIG bits. Builds on the architecture decision from Phase 1: the
`main()`/tick/watchdog-liveness model is **per-MCU shell**; only the leaf hardware
operations are shared through the interface.

## 1. Locked decisions

- **Tick/WDT model = "B" (polled timer + fault watchdog).** A hardware timer
  (TMR2) drives the ~1 ms tick, *polled* in the main loop (no sleep); the WDT is a
  pure fault watchdog at a longer period, `CLRWDT`'d once per tick. Chosen over the
  WDT-periodic-wakeup model because it matches the AVR design more closely and is
  simpler to reason about — and crucially it **dissolves the blocking-actuation
  conflict**: with the WDT at ~32 ms and the worst-case awake burst ≈ 13–14 ms
  (1 ms tick wait + the 12 ms relay/mute pulse + overhead), the blocking actuation
  fits inside one WDT period, so **the output drivers keep their plain
  `__delay_ms`** — no WDT-aware delay abstraction needed. (Trade-off accepted: no
  low-power sleep; fine for an always-powered pedal.)
- **Toolchain (confirmed working):** XC8 v3.10 (`/opt/microchip/xc8/v3.10/bin/xc8-cc`)
  + the PIC10-12Fxxx DFP v1.9.189. XC8's base install has no device-support files
  for this family; the DFP supplies them. Build invocation:
  `xc8-cc -mcpu=10F322 -mdfp=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 …`
  — note `-mdfp` points at the pack's **`xc8/` subdir**, not the pack root (pointing
  at the root gives error 2104). A trivial program builds; device budget =
  **512 words flash / 64 bytes RAM**. Authoritative register/CONFIG reference:
  `<DFP>/xc8/pic/include/proc/pic10f322.h`. gpsim 0.32.1 for simulation.

## 2. Datasheet facts (PIC10(L)F320/322, DS40001585)

Confirmed against the datasheet and the now-installed DFP device header
(`<DFP>/xc8/pic/include/proc/pic10f322.h`); SFR addresses in parentheses.

- **GPIO — only 4 I/O.** `RA0`, `RA1`, `RA2` are bidirectional (and analog-capable);
  **`RA3` is input-only** (shared MCLR/VPP). Registers: `PORTA`(0x05),
  `TRISA`(0x06, 1=input), `LATA`(0x07, output latch — write through this),
  `ANSELA`(0x08, 1=analog; **must be cleared for digital I/O** — pins power up
  analog), `WPUA`(0x09, per-pin weak pull-up), and **`OPTION_REG`(0x0E)`.nWPUEN`
  (bit 7, active-low — *clear* to enable the weak pull-ups)**.
- **Timer2** (1 ms tick source): `T2CON`(0x13: `T2CKPS` prescale 1/4/16, `T2OUTPS`
  postscale, `TMR2ON`), `PR2`(0x12), `TMR2`(0x11), flag **`TMR2IF` = `PIR1`(0x0C)
  bit 1**. At `FOSC`=16 MHz → FOSC/4 = 4 MHz, prescale /16 → 250 kHz, `PR2`=249 →
  exactly 1 ms. Postscale 1:1 so `TMR2IF` sets every period; the loop polls + clears it.
- **WDT** (fault watchdog): time base = 31 kHz LFINTOSC, independent of FOSC.
  `WDTCON`(0x30) = `SWDTEN`(bit 0) + `WDTPS<4:0>`(bits 1–5). ~32 ms ≈ `WDTPS`=0b00101
  (1:1024); confirm the nominal ms in the datasheet WDT period table. Awake WDT
  timeout = device reset (the fault-recovery path we want).
- **Oscillator:** internal HFINTOSC, frequency via `OSCCON`(0x10) `IRCF<2:0>`
  (3-bit; 16 MHz = 0b111, confirm); `FOSC` CONFIG bit = INTOSC.
- **CONFIG (`#pragma config`)** bits available: `FOSC` (INTOSC), `BOREN`
  (ON/OFF/NSLEEP/SBODEN), `WDTE` (ON/OFF/NSLEEP/SWDTEN), `PWRTE`, `MCLRE`
  (ON = MCLR / OFF = RA3 digital input), `CP`, `LVP`, `LPBOR`, `BORV`, `WRT`.

## 3. PIC10F322 pin map (corrected)

Only 4 pins, so the footswitch (an input) goes on the input-only RA3 (`MCLRE=OFF`),
freeing the three bidirectional pins for outputs. Bit positions are PORTA bit
indices.

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

The bit positions differ from AVR for *every* logical pin — which is exactly why
pin assignments must live in a **per-MCU pin map** (see Increment 2a). The relay
and mute variants use all three output pins (zero spare); cd4053-simple leaves RA2
as a spare driven low.

## 4. Contract mapping (how the PIC shell implements each HW op)

Only the GPIO-leaf ops and the output-driver ops are declared in the shared
`bypass_hw_iface.h`; the footswitch / WDT / sleep / `mcu_init` / `tick_timer_start`
rows are **shell-internal** — the PIC shell implements them as its own `static`
functions (as the AVR shell does), not via the shared header.

| HW op                         | PIC implementation                                            |
|-------------------------------|---------------------------------------------------------------|
| `hw_pin_set_high/low(pin)`    | set/clear `LATA` bit                                          |
| `hw_led_pin_set_high/low`     | `LATA` LED bit                                               |
| `hw_configure_output_pins(m)` | `ANSELA &= ~m` (digital); `TRISA = (uint8_t)~m & 0x0F` (outputs); `LATA &= ~m` (low) |
| `hw_output_pins_intact(m)`    | `(TRISA & m) == 0` (the m pins are still outputs)            |
| `hw_read_footswitch`          | read `PORTA` RA3 bit                                         |
| `hw_footswitch_pullup_intact` | check `WPUA` RA3 bit (analogous to AVR checking the PORTB latch) |
| `hw_wdt_pet`                  | `CLRWDT()` (`__asm("clrwdt")` / `__clrwdt()`)               |
| `hw_wdt_arm`                  | WDT is `WDTE=ON` via CONFIG (always-on); arm sets `WDTPS`/no-op |
| `hw_wait_for_tick`            | spin until `TMR2IF`, then clear it (renamed from `hw_sleep_until_tick`) |
| `hw_tick_timer_start`         | configure + start TMR2 (`PR2`, `T2CON`); no interrupt (polled) |
| `hw_mcu_init`                 | `OSCCON` 16 MHz; `ANSELA=0`; footswitch `WPUA` + `OPTION_REG` `WPUEN`; (TRISA set by `hw_init_output_pins`) |
| `hw_force_wdt_reset` (static) | disable interrupts + spin → WDT resets (~32 ms)              |
| driver `hw_set_*` / sanity / `hw_init_output_pins` | unchanged logic; pins from the pin map |

The PIC `main()` (Model B), conceptually parallel to the AVR's but with no ISR and
no `timer_isr_called_` handshake (the single polled loop reaching `CLRWDT` is the
liveness proof):

```
init():  CONFIG bits via #pragma; OSCCON; hw_init_output_pins(); hw_mcu_init();
         hw_set_bypass_state(); ctx = debounce_init_context(hw_read_footswitch());
         hw_tick_timer_start();
loop:    hw_wait_for_tick();                          // poll TMR2IF (~1 ms)
         if (sanity fails) hw_force_wdt_reset();
         ctx.debounce_counter = debounce_integrate(hw_read_footswitch(), ctx.debounce_counter);
         apply debounce_step(ctx) -> outputs on toggle / fault -> reset
         hw_wdt_pet();                                // CLRWDT
```

## 5. Known behavioral divergence (verification item)

On AVR the footswitch is sampled by the Timer0 ISR even *during* the 12 ms
actuation; on PIC (single polled loop) sampling pauses for those ~12 ms. Argued
benign: the actuation is a post-toggle lockout window (`debounce_step` reloaded the
counter to `RELEASE_THRESH`), the switch is held, and re-arm requires
`RELEASE_THRESH` *release* samples that only begin after the user releases — well
after the actuation. To be made an explicit equivalence argument, not just asserted,
during PIC verification.

### 5.1 Concurrency model: single-threaded, so no atomicity requirement

The AVR shell relies on `-fshort-enums` partly for **atomicity**: it samples the
footswitch in the Timer0 ISR and shares `timer_isr_called_` and `ctx_` across the
ISR/`main()` boundary, so those individual shared fields must be 8-bit to be read
and written in a single (uninterruptible) instruction on the 8-bit AVR.

Model B on the PIC has **no such requirement, because it has no second thread.**
It *polls* `TMR2IF` in the main loop — there is no timer ISR, no
`timer_isr_called_`, and `ctx_` is owned solely by `main()` (kept non-`volatile`
to advertise that single-owner invariant). `debounce_integrate()` runs inline in
the polled loop, not asynchronously. One execution context ⇒ nothing is shared
⇒ no atomic-access requirement. This is a second payoff of Model B alongside the
blocking-actuation/WDT resolution above: it also dissolves the ISR-shared-state
hazard, which is why XC8's lack of `-fshort-enums` (it sizes enums as `int`) is
harmless here.

For the record: the PIC10F322 is an 8-bit core and does **not** provide atomic
multi-byte access — a 16-bit `int` (or the 3-byte `debounce_context_t`) read/write
compiles to several instructions and is interruptible mid-operation. So *if* a
future revision ever added an ISR sharing a multi-byte object with `main()`, that
change must add explicit protection (disable interrupts around the access via
`GIE`/`di()`/`ei()`, or share only a single byte) — note an 8-bit enum would not
make a multi-field struct atomic regardless. No such sharing exists today.

## 6. Increment plan

- **2a — pin-name neutralization (AVR-only) — DONE (2026-06-24).** Moved pin
  assignments out of the AVR-named headers into a per-MCU **pin map**
  (`src/bypass_pins_avr_classic.h` now; `src/bypass_pins_pic10f32x.h` in 2b),
  selected by an MCU-family macro. Drivers reference neutral logical pins +
  `BYPASS_OUTPUT_DDR_MASK`; no `PBx`/`<avr/io.h>` left in the drivers. Renamed
  `hw_sleep_until_tick` → `hw_wait_for_tick` (AVR sleeps, PIC polls — same contract).
  Emergent (from verification): the shell-internal helpers became `static` +
  dropped from the interface (MISRA 8.7, §4 above); `BYPASS_OUTPUT_DDR_MASK` is a
  plain `0x1EU` literal (MISRA 10.8); `static_assert`s pin `PBx == ordinal` and the
  logical→physical map; D-2 covers the pin map's per-variant unused macros (2.5).
  `make test` + `make test-mutation` clean.
- **2b — PIC shell + CONFIG + build.** Write `src/bypass_mcu_pic10f32x.c` (Model-B
  `main()`, TMR2 tick, WDT fault, `LATA/TRISA/PORTA/ANSELA/WPUA` GPIO) and
  `src/bypass_pins_pic10f32x.h`; add `#pragma config`; wire Makefile PIC targets
  (`xc8-cc -mcpu=10F322 -mdfp=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8`);
  get it compiling + a flash-budget check (512 words / 64 B RAM). DFP installed.
- **2c — validation — IMPLEMENTED (2026-06-25).** Three host/sim-side checks,
  each a standalone Make target (XC8/gpsim may be absent in CI, so none are wired
  into `make test`); `make pic-test` runs all three.
  - **CONFIG-word check — `make pic-test-config`.** `test/pic/test_config_pic.c`
    parses the CONFIG word XC8 emitted into each built HEX (word 0x2007 / byte
    0x400E, little-endian) and asserts it matches the design intent
    (`0x389E`; implemented bits `0x189E`): FOSC=INTOSC, BOREN=ON, WDTE=ON,
    PWRTE=ON, MCLRE=OFF, CP=OFF, LVP=OFF, LPBOR=OFF, BORV=HI, WRT=OFF, with
    critical cross-checks on WDTE/MCLRE/BOREN. The PIC analogue of `test-fuses`,
    but stronger: it reads the actual compiler output, not a Makefile-injected
    value. Passes (45 checks).
  - **Static analysis — `make pic-analyze`** (`pic-analyze-cppcheck` +
    `pic-analyze-misra`). cppcheck `--platform=pic8-enhanced` over the real XC8 +
    DFP register headers, `-D_10F322` selecting the device header. Plain
    bug-finding pass is clean. MISRA addon is clean except **2 × Rule 10.5**
    (lines 101, 135: an explicit `(uint8_t)` cast of an essentially-Boolean
    result in the two `hw_*_intact` helpers) — *firmware-fixable*: dropping the
    outer cast, as the AVR shell already does, clears it with no new deviation.
    The PIC pin map's Rule 2.5 (and the cross-config AVR pin map) extend the
    existing D-2 deviation; `misra-config` (cppcheck can't value-flow-model the
    SFR bitfield unions) and the XC8/DFP system headers are handled on the
    command line. See `MISRA_COMPLIANCE.md` (PIC shell section).
  - **gpsim register-level test — `make pic-test-gpsim`.** The PIC shell's
    analogue of the AVR simavr suite (the shell has no simavr lock-step). The
    real built HEX runs in gpsim (`-p p10f322`); `test/pic/footswitch_toggle.stc`
    drives RA3 through two momentary presses and snapshots PORTA/LATA at four
    settled checkpoints; `test/pic/run_gpsim_test.sh` asserts the round-trip
    BYPASS -> (press) latched ENGAGED -> (press) BYPASS (LED on RA0, footswitch
    on RA3), plus the per-variant ENGAGED control pins (cd4053 `0x3`, mute `0x7`,
    relay `0x1`). Passes for all three variants.
  - **Firmware fix applied:** the outer `(uint8_t)` cast was dropped from
    `hw_output_pins_intact` and `hw_footswitch_pullup_intact` (return the
    Boolean directly, as the AVR shell does), clearing the 2 × 10.5 with no new
    deviation. `make pic-test` is fully green (CONFIG 45/0, MISRA clean, gpsim
    PASS on all three variants).
- **2d — docs — IMPLEMENTED (2026-06-25).**
  - `TOOLCHAIN.adoc`: new "PIC toolchain" section (XC8 V3.10, PIC10-12Fxxx DFP
    v1.9.189 with the `-mdfp` xc8/-subdir note, gpsim 0.32.1, the
    `--platform=pic8-enhanced` analysis, the XC8 C99/no-`-fshort-enums`/const-ROM
    behaviours, and the 512-word/64-byte budget); the reproduce section gained
    `gpsim` + a note that XC8/DFP are separate Microchip downloads.
  - `DESIGN_DOCUMENTATION.adoc`: Resource Utilization split into "AVR Classic
    family" and a new "PIC10F322 (XC8 build)" sub-table (program words + data
    bytes: cd4053 342, relay 367, mute 372 of 512 words; 34 of 64 B).
  - `README.md`: opening now names both MCU families (AVR Classic + PIC10F322)
    and the shared-core/per-MCU-shell architecture; Quickstart gained the
    `make pic` / `make pic-test` commands.

## 7. Verification strategy

`bypass_pure.c` is unchanged and MCU-neutral, so the host/formal suite
(golden-model, CBMC, model-check, KLEE) **still fully covers the algorithm** for
PIC. The PIC *shell* has no simavr lock-step equivalent — it is validated by static
analysis + the CONFIG-word check + gpsim register-level scripts + real hardware.
The AVR shell remains the more rigorously verified reference.
