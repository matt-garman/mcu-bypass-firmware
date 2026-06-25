# Increment 2b — PIC10F322 hardware shell: implementation spec

Self-contained build instructions for the PIC shell, written so this can be
implemented after the session is compacted. **Design rationale, datasheet facts,
the contract→register mapping, the pin map, and the Model-B `main()` sketch live
in `docs/phase2_pic_shell.md` — read §1–§5 of that first.** This file is the
concrete "what to write."

Branch: `pic10f32x_support`. Model **B** (polled TMR2 1 ms tick + ~256 ms fault
WDT, no sleep). Per AGENTS.md, **firmware edits are the user's**; Claude owns the
Makefile / test wiring and verifies.

## Prereqs (already proven this session)
- XC8 v3.10: `/opt/microchip/xc8/v3.10/bin/xc8-cc`
- DFP: `/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189`
- Build invocation (compiles a trivial 10F322 program):
  `xc8-cc -mcpu=10F322 -mdfp=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 …`
  — note `-mdfp` points at the pack's **`xc8/` subdir** (the pack root → error 2104).
- Budget: **512 words flash / 64 B RAM**.
- Authoritative register/CONFIG reference: `<DFP>/xc8/pic/include/proc/pic10f322.h`
  (confirmed: `PORTA`/`TRISA`/`LATA`/`ANSELA`/`WPUA`, `OPTION_REG.nWPUEN` bit7
  active-low, `TMR2`/`PR2`/`T2CON`, `TMR2IF`=`PIR1` bit1, `WDTCON`=`SWDTEN`+`WDTPS<4:0>`,
  `OSCCON.IRCF<2:0>`).

## Reused unchanged
- `bypass_pure.c` (algorithm) — and the host/formal proofs (golden model, CBMC,
  model-check, KLEE) already cover it for PIC.
- The three output drivers' logic (but see "driver delay" below).
- `bypass_hw_iface.h` — the PIC shell implements the cross-boundary ops and
  provides its own `static` shell-internal helpers.
- `bypass_output_common.h` already has the `#if defined(BYPASS_MCU_PIC10F32X)`
  branch that includes `bypass_pins_pic10f32x.h`.

## Step 1 — prerequisite firmware tweaks (small; do first)
1. **`bypass_config.h`** — guard the AVR-only section. It detects tinyx5, `#error`s
   unless `F_CPU` is the AVR value, and defines `TIMER0_OCR0A_1MS`. Wrap that whole
   MCU-specific block in `#if defined(__AVR__)` so the PIC build gets only
   `PRESSED_THRESH` / `RELEASE_THRESH` (the shared, MCU-neutral truth).
2. **Driver blocking delay** — `relay` + `mute` call `_delay_ms()` (`<util/delay.h>`,
   AVR-only). PIC needs `__delay_ms()` (`<xc.h>`). Neutralize per driver:
   ```c
   #if defined(__AVR__)
   #  include <util/delay.h>
   #  define BYPASS_DELAY_MS(n) _delay_ms(n)
   #else
   #  include <xc.h>
   #  define BYPASS_DELAY_MS(n) __delay_ms(n)
   #endif
   ```
   and call `BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)` etc. Model B's ~256 ms WDT spans
   the 12 ms pulse, so plain blocking delays are fine (no CLRWDT interleaving).
   `cd4053_simple` has no delay — unaffected.

## Step 2 — new file `src/bypass_pins_pic10f32x.h`
```c
#ifndef BYPASS_PINS_PIC10F32X_H__
#define BYPASS_PINS_PIC10F32X_H__
#include <stdint.h>

// PIC10F322 pin map — PORTA/TRISA/LATA bit positions. Only 4 I/O: RA0–RA2 are
// bidirectional, RA3 is input-only (shared MCLR/VPP; MCLRE=OFF) and is the
// footswitch input, freeing RA0–RA2 as outputs.
#define FOOTSW_PIN (3U)       // RA3 (input-only) + weak pull-up
#define LED_PIN    (0U)       // RA0
#define CD4053_PIN (1U)       // RA1   (cd4053 simple)
#define RELAY_RESET_PIN (1U)  // RA1   (relay)
#define RELAY_SET_PIN   (2U)  // RA2   (relay)
#define CD4053_CTL1 (1U)      // RA1   (mute)
#define CD4053_CTL2 (2U)      // RA2   (mute)

// Bits that must be OUTPUTS (RA0–RA2); RA3 stays input. Same macro NAME as the
// AVR map (drivers consume it); value is the output-bit set, interpreted by the
// per-MCU hw_configure_output_pins(). ("DDR" is legacy AVR wording — optional
// future rename across both maps + drivers.)
#define BYPASS_OUTPUT_DDR_MASK (0x07U)  // RA0|RA1|RA2

#endif
```
Relay uses all three outputs (LED RA0, RESET RA1, SET RA2); cd4053-simple leaves
RA2 a spare driven low; mute uses RA0/RA1/RA2. Mask `0x07` for all.

## Step 3 — new file `src/bypass_mcu_pic10f32x.c`
Skeleton (fill in / verify register bits against the DFP header). The PIC shell
mirrors the AVR shell's structure but with a polled loop and no ISR.

```c
#include <xc.h>
#include "bypass_config.h"        // PRESSED_THRESH / RELEASE_THRESH (after the guard)
#include "bypass_output_common.h" // -> pin map (build defines -DBYPASS_MCU_PIC10F32X)
#include "bypass_types.h"
#include "bypass_pure.h"
#include "bypass_hw_iface.h"
#include <assert.h>

// CONFIG — verify names/values against the DFP pic10f322.h config block.
#pragma config FOSC = INTOSC   // internal HFINTOSC
#pragma config BOREN = ON      // brown-out reset
#pragma config WDTE = ON       // watchdog always on (fault watchdog, ~256 ms via WDTPS)
#pragma config PWRTE = ON      // power-up timer
#pragma config MCLRE = OFF     // RA3 is a digital input (footswitch), not MCLR
#pragma config CP = OFF
#pragma config LVP = OFF
#pragma config LPBOR = OFF
#pragma config BORV = LO       // verify
#pragma config WRT = OFF
// NOTE: WDTPS for ~256 ms (≈1:8192 on the 31 kHz LFINTOSC) is set in WDTCON at
// runtime in hw_mcu_init() if WDTE=ON doesn't fix it; confirm from the datasheet.

#define _XTAL_FREQ 16000000UL  // for __delay_ms(); must match OSCCON below

// ---- cross-boundary ops (implement bypass_hw_iface.h) ----------------------
void hw_pin_set_high(uint8_t const pin){ LATA |= (uint8_t)(1U << pin); }
void hw_pin_set_low (uint8_t const pin){ LATA &= (uint8_t)~(1U << pin); }
void hw_led_pin_set_high(void){ LATA |= (uint8_t)(1U << LED_PIN); }
void hw_led_pin_set_low (void){ LATA &= (uint8_t)~(1U << LED_PIN); }
void hw_configure_output_pins(uint8_t const m){
    ANSELA &= (uint8_t)~m;            // digital
    LATA   &= (uint8_t)~m;            // drive configured outputs low
    TRISA   = (uint8_t)(~m & 0x0FU);  // m-bits = output(0); others input(1); RA3 stays input
}
uint8_t hw_output_pins_intact(uint8_t const m){ return (uint8_t)((TRISA & m) == 0U); }
// (hw_set_bypass_state/engaged, hw_is_sanity_check_failed, hw_init_output_pins
//  come from the shared output drivers — reused.)

// ---- shell-internal statics (NOT in bypass_hw_iface.h) ---------------------
static pin_state_t hw_read_footswitch(void){
    return (0U == (PORTA & (1U << FOOTSW_PIN))) ? PIN_STATE_LOW : PIN_STATE_HIGH;
}
static uint8_t hw_footswitch_pullup_intact(void){ return (uint8_t)((WPUA & (1U << FOOTSW_PIN)) != 0U); }
static void hw_wdt_pet(void){ CLRWDT(); }
/* noreturn: use the attribute spelling XC8 accepts, or omit */
static void hw_force_wdt_reset(void){ INTCONbits.GIE = 0; for(;;){ } } // WDT (awake) resets ~256 ms

static void hw_mcu_init(void){
    OSCCON = /* IRCF = 0b111 -> 16 MHz; verify bit layout */;
    ANSELA = 0x00U;                 // all-digital
    WPUA  |= (uint8_t)(1U << FOOTSW_PIN);   // footswitch weak pull-up
    OPTION_REGbits.nWPUEN = 0;      // enable weak pull-ups globally (active-low)
    // TRISA/ANSELA for the variant's output pins are set by hw_init_output_pins().
}
static void hw_tick_timer_start(void){
    PR2   = 249U;          // 16 MHz: Fosc/4=4 MHz, /16 prescale -> 250 kHz, 250 counts = 1 ms
    T2CON = /* T2CKPS=1:16, TMR2ON=1, postscale 1:1; verify bits */;
    PIR1bits.TMR2IF = 0;   // start clean
}
static void hw_wait_for_tick(void){
    while (0U == PIR1bits.TMR2IF) { }   // poll the 1 ms tick (no sleep)
    PIR1bits.TMR2IF = 0;
}

// ---- pin-map sanity (parity with the AVR shell) ----------------------------
// Assert the literal RA positions against the DFP position macros:
static_assert(LED_PIN         == _PORTA_RA0_POSN, "LED_PIN must be RA0");
static_assert(CD4053_PIN      == _PORTA_RA1_POSN, "CD4053_PIN must be RA1");
static_assert(RELAY_SET_PIN   == _PORTA_RA2_POSN, "RELAY_SET_PIN must be RA2");
static_assert(FOOTSW_PIN      == _PORTA_RA3_POSN, "FOOTSW_PIN must be RA3");
// (add the rest; verify the exact _PORTA_RAx_POSN macro names in the DFP header)

// ---- main (Model B: poll TMR2 tick; WDT = fault watchdog) ------------------
void main(void){
    debounce_context_t ctx;
    hw_init_output_pins();   // driver: ANSELA/TRISA/LATA for the active variant
    hw_mcu_init();           // osc, all-digital, footswitch pull-up
    hw_set_bypass_state();   // driver: default bypass (may block on relay/mute pulse)
    ctx = debounce_init_context(hw_read_footswitch());
    hw_tick_timer_start();   // start + clear the tick LAST, before the loop
    for (;;) {
        hw_wait_for_tick();                                   // ~1 ms
        if ((ctx.program_state > RELEASE_DEBOUNCE_WAIT) ||
            (ctx.effect_state  > ENGAGED) ||
            (0U == hw_footswitch_pullup_intact()) ||
            hw_is_sanity_check_failed()) { hw_force_wdt_reset(); }
        ctx.debounce_counter = debounce_integrate(hw_read_footswitch(), ctx.debounce_counter);
        debounce_step_result_t const r = debounce_step(ctx);
        ctx.program_state = r.program_state;
        ctx.effect_state  = r.effect_state;
        if (r.reload_lockout) { ctx.debounce_counter = r.lockout_value; }
        if (r.fault)        { hw_force_wdt_reset(); }
        else if (r.toggled) { if (BYPASS == r.effect_state) hw_set_bypass_state(); else hw_set_engaged_state(); }
        hw_wdt_pet();        // CLRWDT
    }
}
```
Notes/verify: XC8 `noreturn` attribute spelling; exact `OSCCON`/`T2CON` bit values
and `WDTPS` (datasheet §WDT period table); whether `debounce_context_t` on the
stack vs file-static `ctx_` (AVR uses file-static `volatile` because of the ISR;
PIC has no ISR, so a local is fine — confirm with the analysis tools).

## Step 4 — Makefile (Claude's side)
Add: `PIC_CC=/opt/microchip/xc8/v3.10/bin/xc8-cc`,
`PIC_DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8`, `PIC_CHIP=10F322`.
Per-variant build rule:
`$(PIC_CC) -mcpu=$(PIC_CHIP) -mdfp=$(PIC_DFP) -DBYPASS_MCU_PIC10F32X -D<variant macro> \
   src/bypass_mcu_pic10f32x.c src/bypass_pure.c src/<driver>.c -o <out>.hex`
Targets `pic10f322_cd4053|mute|relay`; a flash-budget check (≤ 512 words via the
xc8 summary). The variant macros are `CD4053_WITH_MUTE` / `TQ2_L2_5V_RELAY` /
(none = cd4053 simple), matching the AVR build and the host shim.

## Step 5 — verify
- 2b done = each variant compiles for 10F322 and fits 512 words.
- `make test` (AVR) must stay green (the Step-1 firmware tweaks touch shared files).
- 2c (next increment): `test/pic/test_config_pic.c` parses the HEX and checks the
  CONFIG word; MISRA/cppcheck on `bypass_mcu_pic10f32x.c` (document XC8 deviations);
  gpsim `.stc`/CLI scripts driving the footswitch and asserting `PORTA`/`LATA`.

## Labor split
- **User (firmware):** the `bypass_config.h` guard, the driver delay macro,
  `bypass_pins_pic10f32x.h`, `bypass_mcu_pic10f32x.c`.
- **Claude:** Makefile PIC targets + flash-budget check; `test_config_pic.c`;
  gpsim scripts; MISRA wiring; doc updates. And re-verify after each step.
