# Relay coil fault correction (correct-in-place model)

## Summary

On a detected single-event upset (SEU/EMI) that leaves a latching-relay coil
energized, every relay-capable shell **corrects the coil in place** — it
re-drives both coils to their de-energized state at the top of each serviced
tick, *before* the per-tick sanity gate — instead of forcing a watchdog reset.
A transient upset therefore self-heals within one ~1 ms tick with no reset and
no disruption to the engaged state; a *persistent* coil fault, which the
re-assert cannot fix, still falls through to the sanity gate and resets.

This is the behaviour PIC10F320 has always had; it is now applied uniformly to
every relay-capable shell (PIC10F322, PIC12F675, AVR classic, AVR-XT). It
resolves the "coil energized until watchdog reset" hazard (a 12 ms pulse coil
held hot for a full ~160–480 ms watchdog period) without the ~300 ms audio
dropout and forced-bypass a reset would cause mid-performance.

## Why correct-in-place, not de-energize-then-reset

- **It is a no-op on the nominal path.** Every actuation already ends in
  `set_relay_coils_low()`, and nothing drives a coil high between actuations, so
  the re-assert only does anything once an upset has set a coil bit. It is
  redundant in normal operation and load-bearing only under fault.
- **It degrades on its own.** Re-asserting the coil low *before* the sanity gate
  means a transient upset (a writable latch/shadow/port bit) is cleared before
  the gate runs → no reset. A persistent fault (the pin will not follow, the
  direction is skewed, a peripheral seized the pin) survives the re-assert and is
  caught by the same tick's gate → reset. The response self-selects.
- **It cannot spuriously actuate the latch.** The re-assert repeats every ~1 ms,
  which beats the relay's ~4 ms coil actuation time, so a one-tick coil glitch
  can never flip the mechanical latch.
- **The coil is the only output that needs it.** The relay coil is the one
  output with a continuous-energization / spurious-actuation hazard. The LED and
  the CD4053 control lines have no such hazard, so correction is coil-only (with
  the PIC12F675 caveat below); their upsets keep the uniform reset behaviour.

The trade-off accepted deliberately: a transient coil upset is now **silent** (no
reset, no count). That is the intended minimum-disruption behaviour on parts with
no telemetry.

## Mechanism

`bypass_hw_iface.h` declares one operation:

```c
void hw_outputs_reassert_safe(void);
```

Each output driver implements it:

| Driver | Body | Rationale |
| --- | --- | --- |
| `bypass_output_tq2_l2_5v_relay.c` | `set_relay_coils_low();` | drive both coils to their de-energized idle |
| `bypass_output_cd4053_simple.c` | *(no-op)* | control level tracks the effect state; no fixed safe idle to re-assert |
| `bypass_output_cd4053_with_mute.c` | *(no-op)* | same |

Each modular shell calls it at the top of every serviced iteration, immediately
before the sanity gate (`bypass_mcu_pic10f322.c`, `bypass_mcu_pic12f675.c` right
after `hw_wait_for_tick()`; `bypass_mcu_avr_classic.c`, `bypass_mcu_avr_xt.c` as
the first statement of the main loop). The call is unconditional — the linked
driver decides whether it does anything — so no shell carries a per-variant
`#if`. PIC10F320 keeps its inline `#if defined(OUTPUT_TQ2_RELAY)` re-assert; it is
the reference this brings to the others.

## Per-architecture behaviour

The correction is **coil-only** on every part except the PIC12F675, and the
difference is a direct consequence of each part's output-write primitive:

| Part | `hw_pin_set_low` writes | Coil correction scope |
| --- | --- | --- |
| PIC10F320 | `LATA` latch (read-modify-write) | coil-only |
| PIC10F322 | `LATA` latch (read-modify-write) | coil-only |
| AVR classic (ATtiny13a/25/45/85) | `PORTB` (read-modify-write) | coil-only |
| AVR-XT (ATtiny202) | `PORTA.OUTCLR` (atomic single-bit) | coil-only |
| **PIC12F675** | **whole `GPIO` byte from an SRAM shadow** | **coil + whole-port refresh** |

### PIC12F675 whole-port refresh (inescapable, and safe)

The classic mid-range core has **no `LATx` register**. To avoid the classic
read-modify-write-on-pins defect, the shell keeps an SRAM `gpio_shadow_` and
writes `GPIO = gpio_shadow_` — the *entire* port byte — on every output change.
So re-asserting the coils necessarily **refreshes the whole physical port from
the shadow** each tick. Consequences on the relay variant:

- A **coil** upset (shadow *or* physical port) is corrected — the hazard case.
- **Any** physical-port upset (LED, parked spare) is *also* corrected, because
  the whole-port write re-drives every output pin from the shadow.
- A non-coil **shadow** (intent) upset still resets — the shadow is authoritative
  and its corruption is a genuine fault.
- A **persistent** port fault (a pin that will not follow the refresh) is still
  caught deterministically by the shell's unique port-follows-shadow check →
  reset.

This whole-port refresh is **not optional**: correcting a coil *port* upset — the
actual "port energized the coil" hazard — requires a whole-byte port write, and
on this architecture that write refreshes every output pin. It is safe (persistent
faults still reset; transient LED/spare glitches self-heal to the correct value)
and is consistent with the minimum-disruption intent, so it is accepted.

Net fault posture, PIC12F675 relay variant:

```
shadow.GP1 / shadow.GP2 (coil intent)      -> corrected, no reset
GPIO.GP1 / GPIO.GP2      (coil port)        -> corrected, no reset
GPIO.GP0 / GPIO.GP4      (LED / spare port) -> corrected, no reset  (whole-port refresh)
shadow.GP0 / shadow.GP4  (LED / spare intent) -> RESET
persistent pin-stuck fault                  -> RESET (port-follows-shadow)
SFRs / pull-up / context corruption         -> RESET
```

On PIC10F322, AVR classic and AVR-XT the LED/spare cases (latch or port) still
reset; only the coil bits self-heal.

## Test coverage

Each substrate's fault-injection harness proves both directions — the coil
self-heals with no reset, and a mutant that deletes the re-assert is caught:

| Substrate | Harness | Coil correction assertion |
| --- | --- | --- |
| PIC10F322 (gpsim) | `test/pic/test_fault_pic.cc` | `inject_relay_correction_case` — coil high then low within one iteration, `reset_delta == 0` |
| PIC12F675 (gpsim) | `test/pic/test_fault_pic12f675.cc` | coil + all-port cases as `inject_case(..., expected_resets=0)`; "no reset" transitively proves within-one-tick correction (an uncorrected bit trips the port-follows-shadow gate → reset) |
| AVR classic (simavr) | `test/avr/test_sim.c` `inject_coil_correction` | inject coil latch high while asleep; assert latch re-driven low, no reset, LED still lit, still running |
| AVR-XT (yasimavr) | `test/avr/test_fault_attiny202.py` `CORRECT` mechanism | inject `PORTA.OUT` coil high; assert `OUTCLR` re-clears it with no force-reset |

Deleting the loop-top re-assert (or the coil-clear inside the op) is killed
behaviourally on every substrate: the coil stays energized, the sanity gate
fires, and the "no reset" assertion fails.

## Test-harness note: faithful footswitch on the AVR classic (simavr)

The per-tick re-assert exposed a **simavr fidelity gap**, not a firmware bug. On
the classic AVR, `hw_pin_set_low` takes a runtime pin, so `PORTB &= ~(1<<pin)`
compiles to a full-`PORTB` read-modify-write; the relay shell therefore re-writes
`PORTB` every tick. simavr, left alone, lets that write (which re-asserts PB0's
internal pull-up) override the externally driven footswitch level, so presses
stopped registering. On real hardware this cannot happen — a footswitch closed to
ground overrides the weak internal pull-up, and re-writing an already-enabled
pull-up is a no-op.

The harness now drives the footswitch as a **persistent external pull** via
simavr's `AVR_IOCTL_IOPORT_SET_EXTERNAL`, plus an immediate `avr_raise_irq` for
zero-latency edges (`footsw_set` in `test/avr/test_sim.c`). The external pull
survives PORT writes (the switch beats the pull-up, as on hardware); the raise
avoids the one-tick input latency the persistent-pull-alone path introduced. The
AVR-XT (yasimavr) already models this faithfully (`set_external_state`), and the
PIC gpsim/shadow harnesses were never affected.

## Related

- `TODO.md` `T25-relay-fault-abort` — the durable task this closes.
- `docs/phase2_pic_shell.md` — the PIC Model-B polled-loop design the PIC shells
  share.
- `src/bypass_mcu_pic12f675.c` header comment — the GPIO-shadow rationale.
