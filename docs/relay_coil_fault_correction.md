# Relay coil fault correction (correct-in-place model)

## Summary

During settled operation between relay actuations, every relay-capable shell
**corrects a writable coil-state upset in place**. It re-drives both coils to
their de-energized state at the top of each serviced tick, *before* the per-tick
sanity gate, instead of forcing a watchdog reset. A transient settled-state
upset therefore self-heals within the next serviced iteration (nominally about
1 ms, or 1.024 ms on PIC12F675, plus execution latency) without changing the
logical effect state.

This guarantee does **not** cover the 12 ms blocking actuation pulse. The
loop-top re-assert cannot execute while the relay driver is delayed. An upset in
that window can shorten the intended pulse or energize the inactive or both
coils for nearly the remaining pulse duration. The normal post-pulse clear
commands both coil outputs low if execution completes, but missed or spurious
relay actuation, audio disruption, and an external output path that does not
accept that command remain residual risks.

The settled-state behavior is what PIC10F320 already had; it is now applied
uniformly to every relay-capable shell (PIC10F322, PIC12F675, AVR classic,
AVR-XT). It removes the previous need to wait for watchdog recovery after a
transient writable coil-state upset between actuations.

## Why correct-in-place, not de-energize-then-reset

- **It is a no-op on the nominal path.** Every actuation already ends in
  `set_relay_coils_low()`, and nothing drives a coil high between actuations, so
  the re-assert only does anything once an upset has set a coil bit. It is
  redundant in normal operation and load-bearing only under fault.
- **It corrects before escalation.** Re-asserting the coil low *before* the
  sanity gate means a transient settled-state upset in writable output state is
  cleared before the gate runs, so no reset is needed. A mismatch that remains
  observable after the re-assert reaches the existing sanity response. Only
  PIC12F675 compares a physical port against independent shadow intent; the
  other shells do not claim universal detection of an external stuck pin.
- **It bounds settled-state pulses.** The re-assert repeats every nominal
  ~1 ms, below the relay's specified 4 ms minimum pulse for guaranteed
  actuation. That specification does not prove a shorter pulse is mechanically
  harmless, so even settled-state correction bounds exposure rather than
  excluding unintended movement. During the legitimate 12 ms pulse, the
  re-assert is blocked and unintended relay motion remains possible.
- **The coil is the only output that needs it.** The relay coil is the one
  output with a continuous-energization / spurious-actuation hazard. The LED and
  the CD4053 control lines have no such hazard, so correction is coil-only (with
  the PIC12F675 caveat below); their upsets keep the uniform reset behaviour.

The trade-off accepted deliberately: a corrected transient settled-state coil
upset is **silent** (no reset, no count). That is the intended
minimum-disruption behaviour on parts with no telemetry.

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

These loop-top calls are not serviced while `hw_set_bypass_state()` or
`hw_set_engaged_state()` is inside the blocking relay delay. The shared driver
energizes one coil, blocks for 12 ms, and only then clears both coils.

## Per-architecture behaviour

The following correction scope applies to settled-state upsets between
actuations. It does not describe faults arising during the blocking pulse. The
correction is **coil-only** on every part except the PIC12F675, and the difference
is a direct consequence of each part's output-write primitive:

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

- A settled-state **coil** upset (shadow *or* physical port) is corrected.
- **Any** physical-port upset (LED, parked spare) is *also* corrected, because
  the whole-port write re-drives every output pin from the shadow.
- A non-coil **shadow** (intent) upset still resets — the shadow is authoritative
  and its corruption is a genuine fault.
- A settled-state physical-port mismatch that remains observable after refresh
  is caught deterministically by the shell's unique port-follows-shadow check →
  reset. A stuck-low coil during actuation can prevent motion and then match the
  expected settled-low state; it is not covered by that check.

This whole-port refresh is **not optional**: correcting a coil *port* upset — the
actual "port energized the coil" hazard — requires a whole-byte port write, and
on this architecture that write refreshes every output pin. During settled
operation, a mismatch that remains after refresh resets while transient
LED/spare glitches self-heal to the intended value. This is consistent with the
minimum-disruption intent, so it is accepted.

Settled-state fault posture, PIC12F675 relay variant:

```
shadow.GP1 / shadow.GP2 (coil intent)      -> corrected, no reset
GPIO.GP1 / GPIO.GP2      (coil port)        -> corrected, no reset
GPIO.GP0 / GPIO.GP4      (LED / spare port) -> corrected, no reset  (whole-port refresh)
shadow.GP0 / shadow.GP4  (LED / spare intent) -> RESET
settled persistent observable mismatch      -> RESET (port-follows-shadow)
active-pulse coil stuck low                 -> may evade the settled check
SFRs / pull-up / context corruption         -> RESET
```

On PIC10F322, AVR classic and AVR-XT only settled writable coil state is
re-driven. Other observable output-state mismatches retain their existing reset
behavior; these shells do not independently compare physical pins with intent.

## Test coverage

The correction cases below inject only after actuation has settled. They prove
next-service correction with no reset; a mutant that deletes the loop-top
re-assert is caught:

| Substrate | Harness | Coil correction assertion |
| --- | --- | --- |
| PIC10F322 (gpsim) | `test/pic/test_fault_pic.cc` | `inject_relay_correction_case` — coil high then low within one iteration, `reset_delta == 0` |
| PIC12F675 (gpsim) | `test/pic/test_fault_pic12f675.cc` | coil + all-port cases as `inject_case(..., expected_resets=0)`; "no reset" transitively proves within-one-tick correction (an uncorrected bit trips the port-follows-shadow gate → reset) |
| AVR classic (simavr) | `test/avr/test_sim.c` `inject_coil_correction` | inject coil latch high while asleep; assert latch re-driven low, no reset, LED still lit, still running |
| AVR-XT (yasimavr) | `test/avr/test_fault_attiny202.py` `CORRECT` mechanism | inject `PORTA.OUT` coil high; assert `OUTCLR` re-clears it with no force-reset |

Deleting the loop-top re-assert (or the coil-clear inside the op) is killed
behaviourally on every substrate: the coil stays energized, the sanity gate
fires, and the "no reset" assertion fails.

The PIC shipping-source host harness separately characterizes the excluded
active-pulse window in the shared production relay driver. For both SET and
RESET it injects active-coil-low and inactive-coil-high faults at 1, 6, and
11 ms into the 12 ms delay. PIC10F322 observes its LATA state; PIC12F675 observes
independent SRAM-shadow intent and physical GPIO. The harness records the actual
injection offset and counts every modeled post-injection millisecond, not merely
the requested case. All 12 cases per device show no correction during the
remaining blocking interval and a final modeled low state; the inactive-high
cases make the post-pulse clear load-bearing on PIC10F322. These are residual-risk
characterizations, not evidence that the physical output accepts the write or
that the relay cannot move.

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
simavr's `AVR_IOCTL_IOPORT_SET_EXTERNAL`, <!-- name-contract: exempt (AVR_IOCTL_IOPORT_SET_EXTERNAL is a simavr C macro, not a make variable) --> plus an immediate `avr_raise_irq` for
zero-latency edges (`footsw_set` in `test/avr/test_sim.c`). The external pull
survives PORT writes (the switch beats the pull-up, as on hardware); the raise
avoids the one-tick input latency the persistent-pull-alone path introduced. The
AVR-XT (yasimavr) already models this faithfully (`set_external_state`), and the
PIC gpsim/shadow harnesses were never affected.

## Related

- `CHANGELOG.md` / Git history — the durable record of this work. The
  `TODO.md` `T25-relay-fault-abort` task that tracked it (framed around the
  earlier, rejected abort-path model) was removed on completion, per that file's
  "completed work is removed" convention.
- `docs/phase2_pic_shell.md` — the PIC Model-B polled-loop design the PIC shells
  share.
- `src/bypass_mcu_pic12f675.c` header comment — the GPIO-shadow rationale.
