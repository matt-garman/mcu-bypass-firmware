# PIC Phase 1 — hardware-abstraction refactor

Status: **in progress** on branch `pic10f32x_support` (started 2026-06-23).
Increment 1 complete; Increments 2–3 pending.

This note plans the Phase 1 refactor described in `TODO.md` (Tier 3, "PIC MCU
family support"). Phase 1 is a **restructuring, not a behavioral change** — the
goal is that every existing test passes unchanged at every step. It is shared
groundwork for both the PIC10F32x and the future ATtiny202 (AVR8X) ports.

## 1. Purpose and scope

The firmware must run on multiple MCU families that share the debounce algorithm
(`bypass_pure.c`) but differ completely at the register level. Phase 1 closes the
two abstraction gaps that currently bind the firmware to classic AVR:

- **Gap (a) — inline classic-AVR register code in the MCU shell**
  (`src/bypass_mcu_avr_classic.c`): WDT arm/pet, clock prescaler, ADC/analog-
  comparator disable, power gating, footswitch read (`PINB`), idle sleep
  (`sleep_mode`), the footswitch-pull-up sanity read (`PORTB & (1<<FOOTSW_PIN)`),
  Timer0 CTC setup, and `set_sleep_mode`.
- **Gap (b) — output drivers touch `DDRB` directly**
  (`bypass_output_cd4053_simple.c`, `bypass_output_tq2_l2_5v_relay.c`,
  `bypass_output_cd4053_with_mute.c`): `DDRB = mask` in `hw_init_ddrb_setup()`
  and `DDRB & mask` in `hw_is_sanity_check_failed()`.

The fix: extend `bypass_hw_iface.h` into the complete per-MCU hardware contract,
move the classic-AVR implementations behind it (staying within
`bypass_mcu_avr_classic.c`), and make the drivers MCU-neutral at the register
level.

### Explicitly out of Phase 1 scope (deferred to Phase 2)

- **Pin-*name* neutralization.** The drivers still reference `PBx` pin names via
  the variant headers. Mapping `PBx`→`RAx` for PIC is a Phase-2 concern.
- **A portable `main()`/tick loop.** See §2 — the loop stays per-MCU.
- **Extracting a shared per-tick "apply `debounce_step` result" helper.** Tempting,
  but entangled with the `volatile ctx_` access pattern; defer until the PIC
  `main()` exists and lock-step co-sim can validate a shared helper.
- **The PIC shell itself** (`bypass_mcu_pic10f32x.c`) and its build/sim wiring.

## 2. Architecture decision: the main loop stays per-MCU

Each MCU shell owns its own `main()`, tick mechanism, and watchdog-liveness
model; only the *leaf* hardware operations are abstracted behind the interface.

Rationale: the classic-AVR design samples the footswitch **inside the 1 ms
Timer0 ISR** while `main()` sleeps, and proves liveness via the
`timer_isr_called_` ISR↔main handshake. PIC (Phase 2) uses a fundamentally
different model — no tick ISR; the main loop wakes on the WDT, samples, updates,
and sleeps. A single shared `main()` cannot express both without changing AVR's
ISR-sampling behavior, which would break the documented design and its tests
(lock-step co-sim, ISR-jitter, the handshake mutants). So `main()`, the timer
ISR, `init()` (as orchestrator), and `hw_force_wdt_reset()` remain **file-static
in the shell**; their bodies change only by swapping inline register pokes for
named `hw_*` calls.

## 3. Locked design decisions

- **Pin-direction API is mask-based:** `hw_configure_output_pins(mask)` /
  `hw_output_pins_intact(mask)`. The AVR implementation is literally
  `DDRB = mask` / `(DDRB & mask) == mask` — byte-faithful to the current single-
  write semantics (lowest behavioral risk). The PIC implementation maps the mask
  to `TRISA`.
- **Shell-side ops are declared in the shared `bypass_hw_iface.h`** as the
  documented contract every MCU shell must implement, even though Phase 1's
  per-shell `main()` is each shell's only consumer. This gives Phase 2 a concrete
  checklist of signatures to implement.

## 4. Target `bypass_hw_iface.h` contract (end of Phase 1)

```c
#include <stdint.h>
#include "bypass_types.h"          // pin_state_t

// ---- GPIO leaf ops (MCU shell) ------------------------------------------
void    hw_pin_set_high(uint8_t const pin);
void    hw_pin_set_low (uint8_t const pin);
void    hw_led_pin_set_high(void);
void    hw_led_pin_set_low (void);
void    hw_configure_output_pins(uint8_t const output_mask);   // [Inc 1] was DDRB = mask
uint8_t hw_output_pins_intact   (uint8_t const expected_mask); // [Inc 1] was DDRB & mask

// ---- Footswitch input (MCU shell) ---------------------------------------
pin_state_t hw_read_footswitch(void);             // [Inc 2] was static hw_digital_read_footswitch_pin()
uint8_t     hw_footswitch_pullup_intact(void);    // [Inc 2] was PORTB & (1<<FOOTSW_PIN)

// ---- Watchdog (MCU shell) -----------------------------------------------
void    hw_wdt_arm(void);   // [Inc 2] wdt_reset + clear WDRF + wdt_enable(WDTO_250MS)
void    hw_wdt_pet(void);   // [Inc 2] wdt_reset()

// ---- Power / sleep (MCU shell) ------------------------------------------
void    hw_sleep_until_tick(void);   // [Inc 2] was hw_set_idle_sleep_mode()

// ---- MCU bring-up (MCU shell) -------------------------------------------
void    hw_mcu_init(void);          // [Inc 3] clock prescale, ADC/AC off, power
                                    // gating, footswitch pull-up, IRQ-source clear
void    hw_tick_timer_start(void);  // [Inc 3] Timer0 CTC tick + sleep-mode select;
                                    // started last (see Increment 3 ordering note)

// ---- Output variant (active driver) -------------------------------------
void    hw_set_bypass_state(void);
void    hw_set_engaged_state(void);
uint8_t hw_is_sanity_check_failed(void);
void    hw_init_output_pins(void);   // [Inc 1] renamed from hw_init_ddrb_setup()
```

`hw_force_wdt_reset()` (noreturn; reset mechanism is MCU/compiler-specific) and
the timer ISR stay file-static in the shell — not in the interface.

**Update (Phase 2a, 2026-06-24):** MISRA 8.7 showed the *shell-internal* helpers
shouldn't have external linkage either — each is referenced only within its own
shell. So `hw_read_footswitch`, `hw_footswitch_pullup_intact`, `hw_wdt_arm`,
`hw_wdt_pet`, `hw_wait_for_tick`, `hw_mcu_init`, and `hw_tick_timer_start` were
made `static` and dropped from `bypass_hw_iface.h`. The shared interface now
carries only the genuinely cross-boundary ops: the GPIO-leaf ops (shell→driver)
and the output-driver ops (driver→shell). Each MCU shell implements its own
internal helpers.

## 5. Increment plan

Each increment ends with `make test` (and, where relevant, `make test-mutation`)
green. Implement and verify one at a time.

### Increment 1 — drivers off `DDRB` (gap b) — **DONE**

- `bypass_hw_iface.h`: added `hw_configure_output_pins(mask)` and
  `hw_output_pins_intact(mask)`; renamed `hw_init_ddrb_setup` → `hw_init_output_pins`.
- `bypass_mcu_avr_classic.c`: implemented the two new ops
  (`DDRB = output_mask` / `(DDRB & expected_mask) == expected_mask`); renamed the
  `init()` call site.
- All three drivers: `hw_init_output_pins()` now calls
  `hw_configure_output_pins(mask)`; `hw_is_sanity_check_failed()` now returns
  `hw_output_pins_intact(mask) == 0U`. No driver references `DDRB`.
- Test side: none required (no test references the renamed symbols; the host
  shim only imports pin assignments). `make test` + `make test-mutation` pass.

### Increment 2 — footswitch + WDT + sleep leaf ops (part of gap a)

- `bypass_hw_iface.h`: add `hw_read_footswitch`, `hw_footswitch_pullup_intact`,
  `hw_wdt_arm`, `hw_wdt_pet`, `hw_sleep_until_tick`.
- `bypass_mcu_avr_classic.c`:
  - rename `static ... hw_digital_read_footswitch_pin()` → `hw_read_footswitch()`
    (non-static); update the ISR and `init()` call sites.
  - `hw_footswitch_pullup_intact()` ≡ `(PORTB & (1 << FOOTSW_PIN)) != 0`.
  - `hw_wdt_arm()` ≡ the `wdt_reset(); MCUSR &= ~(1<<WDRF); wdt_enable(WDTO_250MS);`
    block; `hw_wdt_pet()` ≡ `wdt_reset()`; `hw_sleep_until_tick()` ≡ `sleep_mode()`.
  - rewire `main()`'s sanity block to use `hw_footswitch_pullup_intact()`, and the
    tick body to use `hw_wdt_pet()` / `hw_sleep_until_tick()`.
- Test side (owned by the harness work, not firmware): the mutation entry
  `"... wdt_reset(); // \"pet the dog\" ..."` in `test/run_mutation_tests.sh`
  targets a source string that becomes `hw_wdt_pet();` — update that entry so the
  mutant still kills. The `timer_isr_called_ = TIMER_ISR_CALLED;` mutant is
  unaffected (stays in the ISR).

### Increment 3 — `hw_mcu_init()` + `hw_tick_timer_start()` (rest of gap a)

Originally planned as a single `hw_mcu_init()`, but two ordering constraints
straddle the driver's `hw_set_bypass_state()` call and force a **two-function**
split:

1. The footswitch pull-up write (`PORTB = (1 << FOOTSW_PIN)`, a full assignment)
   must run **before** `hw_set_bypass_state()` — otherwise it clobbers the
   LED/control bits bypass just set — and **after** `hw_init_output_pins()` so the
   configured outputs are driven low.
2. The Timer0 *start* must run **after** `hw_set_bypass_state()`'s blocking
   relay/mute actuation (up to 12 ms), with `OCF0A` cleared immediately before
   `sei()`. If the timer started before that delay, the accumulated compare-match
   would fire one spurious integrate at `sei()` — a one-tick lock-step divergence.

So:

- `bypass_hw_iface.h`: add `hw_mcu_init` and `hw_tick_timer_start`.
- `bypass_mcu_avr_classic.c`:
  - `hw_mcu_init()` — clock prescale, ADC/AC disable, power gating, footswitch
    pull-up write, `GIMSK`/`PCMSK` clear. (ADC disabled before its clock is gated.)
  - `hw_tick_timer_start()` — Timer0 CTC config + `set_sleep_mode(SLEEP_MODE_IDLE)`.
  - `init()` becomes a thin orchestrator with **no inline register access**.
- **Exact ordering to preserve** (guarded by `test_wdt_rearm_window` and lock-step
  co-sim):

  ```
  cli();
  hw_wdt_arm();           // FIRST — post-reset WDT window
  hw_init_output_pins();  // driver: DDRB — MUST precede the pull-up write
  hw_mcu_init();          // clock/power/peripherals; footswitch pull-up; IRQ-source clear
  hw_set_bypass_state();  // driver (may block on relay/mute pulse)
  ctx_ = debounce_init_context(hw_read_footswitch());
  timer_isr_called_ = TIMER_ISR_NOT_CALLED;
  hw_tick_timer_start();  // LAST — after the blocking actuation
  sei();
  ```
- Test side: none — no mutation entries target the moved lines.

After Increment 3, `init()` and `main()` contain no direct AVR register access;
the only AVR-intrinsic shell code remaining is the timer ISR and
`hw_force_wdt_reset()`, which stay shell-internal by design (§2).

## 6. Division of labor

Per `AGENTS.md`, the **firmware source edits are the user's**. Claude designs the
change, owns the build/test side (Makefile, `run_mutation_tests.sh` mutation
entries, any host shims), and runs verification after each increment.

## 7. Verification strategy

- Host/formal tests (`test/host`, `test/formal`) compile **only** `bypass_pure.c`
  — they do not see the shell or drivers, so they act as an **unchanged control**.
- The simavr suite (`test/avr`) runs the real compiled firmware ELF and is the
  **behavioral-equivalence oracle**: lock-step co-sim (byte-for-byte vs. the
  golden model), `test_wdt_rearm_window`, fault injection, and the WDT-handshake
  checks would all flag any behavioral drift.
- `make test-mutation` confirms the suite still detects injected faults after the
  mutation entries are re-pointed.

## 8. After Phase 1

Phase 1 leaves `bypass_hw_iface.h` as the full hardware contract and
`bypass_mcu_avr_classic.c` as a clean reference implementation of it. Phase 2
adds `bypass_mcu_pic10f32x.c` implementing the same contract (mask→`TRISA`,
WDT-periodic-wakeup `main()`, XC8 specifics) plus its build and gpsim test
wiring. The ATtiny202 (AVR8X) shell, `bypass_mcu_avr_xt.c`, follows the same
pattern.
