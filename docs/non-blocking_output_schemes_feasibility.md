# Non-blocking output schemes — feasibility

**Status:** feasibility assessment. Nothing here is implemented; no `src/` change
has been made or is proposed for merge. It records what was measured on the real
toolchain, what a redesign would have to do rather than copy, and what remains
unpriced — so the decision to start (or not start) can be taken on evidence.

**What this document establishes:**

1. The PIC10F322 **cannot afford the AVR's ISR concurrency model**, and the
   binding resource is **not flash** — it is the 8-level hardware return stack.
   The relay variant lands at 6 levels used against a budget of 8 with a 2-level
   reserve: **zero spare**. Measured (§2.3).
2. The self-health checks cost **132 words**, about 26% of the part, and the ISR
   needs only 2 — so there is ample room to trade. But the checks buy **flash and
   nothing else**: the relay's deep call chain is entirely output-driver code and
   contains no check at all, so ablating every one of them leaves the stack
   unchanged (§2.4). Trading them is paying in the wrong currency.
3. **Non-blocking actuation reaches the same goal from the other side.** Instead
   of letting a second execution context run *through* a blocking delay, it
   removes the blocking delay. It needs no ISR, no extra stack level, no +38
   words, and no checks surrendered — and it can deliver a uniform accepted-tick
   sampling model on *every* platform including the AVR, not just parity between
   two of them (§3). Exact physical output timing still needs per-shell bounds.
4. The API shape this needs is **already the shape of the drivers**. Both
   blocking drivers are exactly `pre-action; one delay; post-action` — verified
   against the source, not assumed (§3.1). It must be **four functions, not two**:
   a target-state parameter is a literal at every call site and free-tier XC8
   still charges for it. Measured (§3.2, §6.2).
5. It is **not free**, and on the PIC10F322 a major cost lands on the very
   checks §2 was trying to protect: a deliberate transient window appears in
   which the output latches match neither BYPASS nor ENGAGED, and
   `hw_is_sanity_check_failed()` must learn about it (§5.1). That cost is
   **unmeasured** there and is one of the first things a spike should price.
6. **The PIC10F320 — the most constrained part — fits the minimal countdown
   shape.** Compiled, linked, flash-budgeted and stack-gated, but not run through
   functional or qualification lanes (§6, especially §6.8): +0 / +8 / +8 words,
   the return stack unchanged, and §5's phase-aware latch-check adaptation cost is
   *zero* because this part already omits the output-latch check that the cost
   falls on. What does not fit is
   range-checking the new state variable: that costs 4 words and puts the relay
   variant exactly on 256, unlinkable (§6.4).
7. **It drops a relay-coil safety property that nothing else in the original
   assessment noticed.** The blocking form cannot pet the watchdog while a coil
   is energized; the naive non-blocking form pets it twelve times. The coil-on
   window goes from watchdog-bounded to unbounded. On the PIC10F320, the worst
   failure — the countdown cleared mid-pulse, so the de-energize never runs — is
   invisible to its direction-only output check. Two mitigations cost 2 and 3
   words, neither subsumes the other, and the PIC10F320 relay variant affords
   exactly one (§7).
   That is a useful feasibility result and **not an acceptable final safety
   policy**: if complete containment cannot be made to fit, that variant should
   remain blocking. This also qualifies §4's strongest argument (§7.7).
8. **Startup is a separate concurrency case, and the original no-overlap proof
   does not cover it.** The spike starts a 12-tick RESET pulse in `init()` and lets
   the normal loop finish it. If the switch is sampled released and then pressed,
   `PRESSED_THRESH` is only 8 ticks: a legitimate first toggle can arrive while
   the startup pulse still has four ticks remaining (§5.3). Startup must be
   serialized or represented by an explicit boot phase that cannot accept an
   output request.
9. **The 1 ms tick becomes part of the relay's safety mechanism.** A blocking
   CPU-cycle delay still lowers the coil if the tick timer fails; a tick-counted
   pulse does not. A stopped timer can hold the coil until watchdog reset and then
   repeat the same long startup pulse after every reset, while a false-fast tick
   source can shorten the pulse below its intended bound (§7.10). Configuration
   readback proves neither tick progress nor cadence.
10. **Fault entry must become output-aware.** Every current
    `hw_force_wdt_reset()` disables interrupts and spins without first removing
    output drive. A sanity fault discovered during a non-blocking relay pulse can
    therefore preserve the energized coil for the remaining watchdog interval,
    potentially almost a complete period (§7.9). The redesign needs a
    target-specific, electrically effective abort
    before entering the reset wait.
11. **The one-byte countdown creates additional valid-but-wrong states.** An
    upper range check catches values above the configured duration and cannot
    catch a shortened in-range value, zero written early, a wrong target, or an
    output request while already active. The state protocol, write ordering and
    busy-request policy are part of the design, not implementation detail (§5.5,
    §7.11).
12. **Withholding `CLRWDT()` changes the test architecture.** Both PIC real-HEX
    lock-step and PIC10F320 host equivalence use the loop's watchdog pet as their
    once-per-iteration observation point, and the PIC fault harness injects there.
    Omitting that instruction for 5 or 12 healthy iterations hides the exact new
    state those lanes must observe (§6.7, §7.13). They need a watchdog-independent
    tick boundary.

**Date / branch:** measurements taken 2026-08-05. §2 and the original §3–§5
feasibility work used `main` @ `59d55e9`; §6 and the original §7 measurements
used `main` @ `831d1d3`. The 2026-08-06 architecture/FMEA review through `main` @
`cf29e12` added the startup, timer-cadence, fault-entry, state-protocol and
validation findings without changing any measured word count.

**Toolchain used for every figure below** — the versions pinned in
`TOOLCHAIN.adoc`, with no additions:

| Tool | Version | Where |
|---|---|---|
| XC8 (free tier) | v3.10 | `/opt/microchip/xc8/v3.10/bin/xc8-cc` |
| Device pack | PIC10-12Fxxx DFP v1.9.189 | `/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8` |

> Scope note: every figure here comes from **throwaway spikes** written outside
> the repository — an ISR-converted copy of the shipping
> `src/bypass_mcu_pic10f322.c`, a macro-ablatable copy of each shell used to price
> the checks one at a time, and (for §6 and §7) eight non-blocking transforms of
> `src/bypass_mcu_pic10f320.c`. None is proposed code and none is checked in. §10
> lists the exact edits behind every number.

---

## 1. Where this came from

The AVR and PIC designs differ in a way that is easy to state: the AVR is loosely
multi-threaded. Its 1 ms timer ISR integrates the footswitch while `main()` does
everything else, so when `main()` blocks for a 12 ms relay coil pulse, debouncing
keeps running underneath it. The PIC shells are Model B — a single polled loop
(`docs/phase2_pic_shell.md` §1) — so the same 12 ms pulse stops the debounce
integrator dead.

The consequence is real but small: on the relay variant the re-arm window
stretches by the pulse width. `RELEASE_THRESH` is 25 ticks, so ~25 ms becomes
~37 ms before the footswitch can be pressed again. The toggle itself is
unaffected, because it has already happened — the effect switches on the press,
and the coil pulse fires afterwards. Nothing audible changes.

What *does* change is uniformity. The project's value proposition is
reference-quality firmware whose behaviour is the same everywhere, and "the same
everywhere except the PIC parts, during actuation, on two of three variants" is a
caveat with a maintenance cost attached. The question that opened this
investigation was therefore whether the PIC10F322 could simply run the AVR's
model — and, when it turned out not to, whether the self-health checks could be
thinned to make room.

The answer to the second question is the interesting one, and it is *no* — but
not for the reason anyone expected.

---

## 2. The measurement: what stops the PIC10F322

### 2.1 What the self-health checks cost

Each check in the main-loop guard was ablated individually, via a macro-switched
copy of the shell, and the image re-linked. Measured on `cd4053_with_mute`
(baselines: 471 words polled, 509 words with an ISR):

| Check | Frees (polled) | Frees (ISR) |
|---|---|---|
| `ctx_.program_state > RELEASE_DEBOUNCE_WAIT` | 4 | 4 |
| `ctx_.debounce_counter > RELEASE_THRESH` | 4 | 4 |
| `ctx_.effect_state > ENGAGED` | 4 | 4 |
| `timer_isr_called_` handshake range | — (absent) | 4 |
| `hw_footswitch_pullup_intact()` | 24 | 24 |
| `hw_is_sanity_check_failed()` → `hw_output_state_intact()` | 54 | 54 |
| `hw_critical_sfrs_intact()` | 42 | 42 |
| **Total (shipping shell)** | **132** | — |

132 words is 25.8% of the part. The intuition that flash growth has been driven
by checks, and that there is slack to reclaim, is correct and then some.

### 2.2 What the ISR costs in flash

| Variant | Polled (shipping) | ISR | Δ |
|---|---|---|---|
| `cd4053_simple` | 445 (86.9%) | 483 (94.3%) | +38 |
| `cd4053_with_mute` | 471 (92.0%) | 509 (99.4%) | +38 |
| `tq2_l2_5v_relay` | 473 (92.4%) | does not link | — |
| RAM (all variants) | 34 B (53.1%) | 43 B (67.2%) | +9 |

The relay failure is worth stating precisely, because "misses by two words" is
the linker's message but not the whole mechanism:

```
error: (1347) can't find 0x2 words (0x2 withtotal) for psect "text18"
in class "CODE" (largest unused contiguous range 0x1)
```

This is **fragmentation at 511 of 512 words**, not a 514-word program. The image
needs two *contiguous* words and the largest free run is one — the ISR vector at
0x0004 splits the code space. (511 is an inference: four independent ablations
that each free 4 words all land at 507, and the linker never reports a total for
a build that fails. The exact figure does not affect any conclusion below.)

Any single ablation from §2.1 buys the relay build. The cheapest is one range
check, at 4 words, landing at 507/512:

| Ablation | Result |
|---|---|
| any one of the four range checks | 507 words — links |
| `hw_footswitch_pullup_intact()` | 487 words — links |
| `hw_critical_sfrs_intact()` | 469 words — links |
| `hw_is_sanity_check_failed()` | 457 words — links |

So on the flash axis the trade is not merely possible, it is overwhelming.

### 2.3 What the ISR costs on the return stack

This is the axis that decides the question. Both oracles of
`test/check_stack_depth_pic.sh` — the longest chain in the emitted instruction
stream, and XC8's own `callstack` directives — agree on every row:

| Build | main tree | ISR tree | Used | + reserve 2 | Spare |
|---|---|---|---|---|---|
| polled `cd4053_simple` *(shipping)* | 3 | — | 3 | 5 | 3 |
| polled `cd4053_with_mute` *(shipping)* | 3 | — | 3 | 5 | 3 |
| polled `tq2_l2_5v_relay` *(shipping)* | 4 | — | 4 | 6 | 2 |
| ISR `cd4053_simple` | 3 | 2 | 5 | 7 | 1 |
| ISR `cd4053_with_mute` | 3 | 2 | 5 | 7 | 1 |
| **ISR `tq2_l2_5v_relay`** | 4 | 2 | **6** | **8** | **0** |

The trees sum rather than max, because an interrupt can arrive at the deepest
point of the main tree; the ISR tree also carries the return address the hardware
pushes on entry. The device pack declares `STACKDEPTH=8` and the overflow is
silent on this core — no STKPTR, no STKOVF, no stack-overflow reset — so the
2-level reserve is what stands between a bench debugger and an undetectable
wrong-return.

### 2.4 Why trading checks does not solve it

The relay variant's 4-level main chain is:

```
_main -> _init -> _hw_set_bypass_state -> _set_relay_coils_low -> _hw_pin_set_low
```

Every edge is output-driver code reached from `init()`. **Not one self-health
check appears in it.** Ablating all 132 words from §2.1 leaves this chain at 4
levels and the ISR relay build at 6 used, 0 spare.

Nor can the chain be flattened cheaply. `hw_pin_set_low()` is the hardware
abstraction boundary; the driver cannot write `LATA` directly without breaking
the portability contract it shares with the AVR, and XC8's free tier has no
link-time optimization to inline across that boundary on its own.

So the honest summary of the ISR option on the PIC10F322 is: it costs 511 of 512
words and uses 6 of 8 hardware stack levels on the variant that most needs it,
leaving no margin beyond the deliberate 2-level reserve. The currency available
to pay with buys only flash, not stack margin. There is also an irony worth
recording — `cd4053_simple` is the one variant with comfortable room (483 words,
1 stack level spare beyond the reserve) and it is the one variant that never
blocks, so it gains nothing from an ISR at all. **The variants that need the
concurrency are exactly the ones that cannot afford it.**

---

## 3. The alternative: remove the blocking delay instead

The ISR model lets a second execution context keep running *through* a blocking
delay. The other way to reach the same place is to stop blocking.

Drive the coil pulse and the mute gap as a tick-counted state in the existing
tick service. Every platform already has a nominal 1 ms accepted tick; an
actuation that takes 12 ms becomes a countdown of 12 serviced ticks rather than
12 ms spent inside `__delay_ms()`. Treating those as twelve milliseconds depends
on the cadence and WCET contracts made explicit in §5.5 and §7.10.

### 3.1 Both blocking drivers already have the right shape

This is the part that makes the redesign tractable, and it is verified against
the source rather than assumed. Every actuation in both blocking drivers is
`pre-action; exactly one delay; post-action`, with the delay always in the middle:

| Driver / target | pre | delay | post |
|---|---|---|---|
| relay → BYPASS | coils low, LED low, RESET high | 12 ms | coils low |
| relay → ENGAGED | coils low, LED high, SET high | 12 ms | coils low |
| mute → BYPASS | LED low, CTL1 low | 5 ms | CTL2 low |
| mute → ENGAGED | CTL1/CTL2 low, LED high, CTL2 high | 5 ms | CTL1 high |
| `cd4053_simple` → either | everything | — | — |

There is no driver with two delays, none with a delay at the start or end, and
none whose delay length depends on runtime state.

### 3.2 The interface

A `_pre` / `_post` split maps directly onto that table, one pair per direction:

```c
void hw_set_bypass_pre(void);
void hw_set_bypass_post(void);
void hw_set_engaged_pre(void);
void hw_set_engaged_post(void);
```

**An earlier revision of this document recommended a two-function form instead**,
passing the target state — `hw_actuation_begin(effect_state_t)` /
`hw_actuation_end(effect_state_t)` — on the grounds that the mute driver's *post*
action genuinely differs between directions (`CTL2` high versus `CTL1` low), so
the direction has to be available somewhere anyway.

That reasoning is sound in C and wrong on this compiler, and §6.2 measures it:

| Form | `cd4053_simple` | `cd4053_with_mute` | `tq2_l2_5v_relay` |
|---|---|---|---|
| two functions, `effect_state_t` parameter | +20 words | **does not link** | +8 words |
| four functions, no parameter | **+0 words** | +8 words | +8 words |

Free-tier XC8 does not propagate a constant through a call boundary. Every call
site passes a literal `BYPASS` or `ENGAGED` and the compiler still emits a runtime
branch *inside* each function — so the parameter is paid for at every variant,
including the one that has no delay to defer and should therefore be free.

This constraint is not new to this proposal. It is already recorded in
`src/bypass_mcu_pic10f320.c`, in the comment explaining why each output pin gets
its own set-high/set-low function rather than a parametric
`hw_pin_set_high(pin)`: *"free-tier XC8 does not propagate that constant through a
function-call boundary, so a parametric helper compiles to a real runtime shift
loop."* The same reasoning governs the actuation API, and the four-function shape
is the one that respects it.

The direction the *post* half needs is then read from `ctx_.effect_state` at the
single point where the countdown expires, instead of being threaded through four
call sites.

The duration is already a per-driver compile-time constant
(`TQ2_L2_5V_PULSE_MS` = 12, `CD4053_MUTE_DELAY_MS` = 5, and 0 for
`cd4053_simple`), so it can be exposed as a macro — `BYPASS_ACTUATION_TICKS` —
with no runtime query to pay for.

### 3.3 What the shell takes on

One byte serving as both active-state marker and countdown in the existing loop:

```c
static uint8_t actuation_ticks_;   /* 0 == idle */
```

On a toggle, load the active countdown and call the `_pre` half for the new state.
On each subsequent tick, decrement values above one; when the value is one, call
the `_post` half selected by `ctx_.effect_state` and only then write the zero/idle
value. That ordering is load-bearing: active must become visible before an output
is energized, and idle must not become visible until the output is physically
settled. The throwaway spike loaded the counter around the `_pre` call and
decremented to zero before `_post`; an implementation should tighten that ordering
rather than copy it literally.

The four driver functions must not become four generally usable operations. A
single shell-owned orchestration block must be their only caller and must define
an active-request policy. For this firmware, `res.toggled` while an actuation is
already active should be a fault, not an implicit restart, reversal or queue: all
three alternatives can lengthen or misdirect a relay pulse. Fault-free runtime
debounce proves the condition unreachable (§5.2), but startup and corrupted
valid state can still express it (§5.3, §7.11).

Wrapping the state and countdown block in
`#if (BYPASS_ACTUATION_TICKS > 0U)` compiles it away entirely where the count is
zero, so `cd4053_simple` degenerates to today's code — measured byte-for-byte
identical, not asserted (§6.2).

Note this replaces a *blocking* dependency with a *state-and-timebase*
dependency. The loop gets more complex and the ordinary sampling story gets
simpler; the output fault-containment story gets wider. The latter is the cost
that §7 makes explicit.

---

## 4. The simplification case

The reason to take this seriously is not the relay variant. It is that a pile of
existing complexity exists only to accommodate blocking, and would be deleted:

- **`src/bypass_blocking_delay.h` disappears entirely.** That header exists only
  to paper over avr-libc's `_delay_ms()` versus XC8's `__delay_ms()`. Deleting a
  portability shim is a real reduction in surface, not a relocation of it.
- **The tick-stealing divergence can go away.** `docs/phase2_pic_shell.md` §5
  documents it as accepted behaviour; it stops existing rather than staying
  documented if every currently blocking target/variant is converted.
- **The soak harness stops needing per-variant timing.** `pic_soak_block_*` in
  the Makefile (0 / 5 / 12) and the `SOAK_PRESS_HOLD_MS = PRESSED_THRESH +
  SOAK_ACTUATION_BLOCK_MS + 10` arithmetic in `test/pic/test_soak_pic.cc` exist
  purely to widen the stimulus windows by the block length. Both collapse to one
  variant-independent number if the matrix converts completely; any deliberately
  retained blocking fallback keeps a corresponding qualification branch.
- **Both watchdogs could tighten.** The PIC's ~256 ms (`WDTPS` 1:8192) and the
  AVR's `WDTO_250MS` are both sized for a worst-case pet-to-pet window dominated
  by the coil pulse — ~14 ms on the PIC (1 ms tick + 12 ms pulse; the PIC pets at
  the end of the loop body) and ~13 ms on the AVR (which pets before actuating).
  A naive non-blocking loop collapses that window to roughly one tick, which
  would permit a materially shorter watchdog period on both families.

  > **Qualified by §7.7.** Output-progress liveness argues for withholding the
  > pet during every deferred actuation, and relay energy makes that mandatory.
  > The watchdog therefore cannot collapse to a one-tick period: its minimum must
  > remain above the longest healthy actuation plus WCET and margin. It can still
  > be materially shorter than 250/256 ms if the selected period has adequate
  > tolerance margin, and shortening it would improve the stalled-output bound.
  > This is a constrained reliability opportunity, not the original free win.

The interface gets wider (two functions where there was one call site) and the
ordinary debounce-timing model gets narrower (one sampling story instead of
two). That is a real simplification, but it is not a net-complexity result by
itself. The scheduler must be expressed in three modular shells and again in the
manually maintained PIC10F320 shell; output sanity becomes phase-aware; startup,
fault entry and watchdog eligibility gain new policy; and several validation
lanes lose their current observation boundary. Deleting the delay shim and soak
arithmetic removes source, while the new safety state machine adds more than can
be counted meaningfully in lines.

The defensible narrower claim is therefore: **non-blocking actuation simplifies
normal timing and portability, while complicating fault containment and
qualification.** Whether that is a project-level simplification depends on the
rest of this document's safety requirements being implemented, not just on the
four-function API fitting flash.

---

## 5. The costs

### 5.1 The sanity checks gain a transient state — unpriced

This is the real cost, and it lands squarely on §2's subject matter.

`hw_is_sanity_check_failed(effect_state)` asserts that the output latches match
the logical state, and that assertion holds today *because* actuation completes
inside a single call — there is no observable moment where the pins disagree with
the state. Non-blocking actuation deliberately creates one: for 12 ticks the
relay coils are energized, matching neither the BYPASS latch pattern nor the
ENGAGED one.

The check must therefore learn transient expectations, or be suppressed across
the window. "A third state" is useful shorthand and not the complete contract:

- relay-to-BYPASS expects RESET high, SET low and the LED low;
- relay-to-ENGAGED expects SET high, RESET low and the LED high;
- mute-to-BYPASS expects `(CTL1, CTL2) = (0, 1)` and the LED low;
- mute-to-ENGAGED expects the same control pair and the LED high.

Direction can be inferred from `ctx_.effect_state` during a normal runtime
transition, but startup adds an ambiguity. The muted driver's power-on BYPASS
`_pre` runs from pins that are already all low, so
`effect_state == BYPASS && actuation_ticks_ > 0` can mean either settled all-low
startup BYPASS or the `(0, 1)` runtime mute state. The clean options are to omit
the electrically redundant startup mute delay, serialize startup outside the
normal scheduler, or encode a boot/source phase. Accepting both latch patterns as
"intact" would weaken the check precisely where the redesign is meant to make
state explicit.

Every exact option costs flash on a part where §2 established there is little to
spare, and "suppressed" is the option that quietly weakens exactly the SEU/EMI
detection the project treats as a first-class requirement. Suppression also
throws away one genuine advantage of non-blocking execution: a wrong coil,
simultaneous coils or invalid mute pattern could otherwise be detected on the
next tick, while the blocking implementation cannot inspect a pulse in progress.

**This is unmeasured on the PIC10F322.** It is one of the first things a spike
should price there, because it determines whether phase-aware validation fits or
merely relocates the squeeze. Fitting it is necessary and, after §7, not
sufficient for the proposal as a whole.

On the PIC10F320 the same cost is **zero**, for a reason that inverts the
expected ordering between the two parts — §6.3.

### 5.2 A second runtime toggle can now land mid-actuation — and normally does not

Today the blocked loop makes this impossible by construction. Non-blocking makes
it expressible, so it must be shown unreachable rather than assumed.

It is unreachable, with margin. After a toggle the debounce enters release-wait
and needs `RELEASE_THRESH` (25) high samples followed by `PRESSED_THRESH` (8) low
samples before it can toggle again: 33 ticks minimum, against a 12-tick pulse.

Both drivers already carry the guarding assertion:

```c
static_assert(TQ2_L2_5V_PULSE_MS < RELEASE_THRESH, ...);
static_assert(CD4053_MUTE_DELAY_MS < RELEASE_THRESH, ...);
```

Those assertions do not become obsolete under the redesign — they get *promoted*.
Their justification changes from "the block must not steal too many ticks from
the release budget" to "no second fault-free runtime toggle can land inside an
actuation window". Same constraint, stronger reason, and it should be re-commented
rather than reused silently.

The qualifiers matter. The argument starts after a toggle has loaded the release
lockout. It says nothing about startup, and valid-but-wrong corruption of
`ctx_.program_state` from `RELEASE_DEBOUNCE_WAIT` to `PRESS_DEBOUNCE_WAIT` can
make `debounce_step()` toggle again with an otherwise in-range context. The
orchestrator still needs an explicit active-request fault path; debounce timing is
a proof of normal reachability, not an API interlock.

### 5.3 Startup can overlap the first toggle

The original spike starts power-on BYPASS actuation in `init()` and lets the
normal loop complete it (§10). That is not equivalent to a post-toggle actuation.
For a footswitch sampled released, `debounce_init_context()` enters
`PRESS_DEBOUNCE_WAIT` with a zero counter. A press beginning immediately after
that sample reaches `PRESSED_THRESH` in 8 accepted ticks, while the relay's
startup RESET pulse lasts 12 ticks. A completely legitimate first ENGAGE request
can therefore arrive with four startup ticks remaining.

Today's firmware cannot express that overlap. Every shell completes the startup
output call before initializing the debounce context and starting the tick. A
non-blocking redesign must preserve the same ordering contract in one of three
ways:

1. **Serialize a tick-driven boot actuation before debounce starts.** Start the
   timer solely to advance the output sequence, finish and park the outputs, then
   sample the footswitch and initialize normal debounce. This best preserves
   current semantics but needs shell-specific boot orchestration.
2. **Retain a blocking startup path.** Small conceptually, but it preserves the
   delay abstraction and two timing mechanisms that §4 wants to remove.
3. **Add an explicit boot-actuating phase.** Normal ticks may run, but input
   requests are not accepted until output completion; the switch is sampled for
   debounce initialization at that point. This is the most explicit and likely
   the most expensive.

Simply calling a new `_pre` and reloading the countdown on the tick-8 request is
not an acceptable fourth option. It silently truncates the RESET pulse and turns
normal startup timing into the busy-request policy.

### 5.4 The drivers are shared, so the AVR moves too

`src/bypass_output_*.c` is common to both families. Changing the driver interface
re-baselines the AVR simavr lock-step tests, the mutation lanes, and any formal
lane that models actuation. That is what the suite is for, but it is the bulk of
the work — the driver edit itself is small.

This also means the change cannot be scoped to "the PIC problem". It is a
project-wide interface change, which is an argument both for it (uniformity is
the goal) and for doing it deliberately rather than incrementally.

The PIC10F320 is the exception in the other direction: it links none of the
shared drivers, so nothing propagates to it automatically and it must be
converted by hand — see §6.7.

### 5.5 The protocol and timing become first-class contracts

The synchronous API currently has one strong postcondition: when
`hw_set_*_state()` returns, the outputs are settled. Splitting it creates several
representable misuse states: `_pre` without `_post`, the wrong direction's
`_post`, a second `_pre` while active, idle published before settling, and output
energized before active state is published. The C type system prevents none of
them. The four functions should remain driver primitives called only by one
shell-owned orchestrator, and the orchestrator's state transitions should have a
small independent specification suitable for exhaustive checking.

The time contract must likewise be stated in accepted hardware ticks, not
informally as milliseconds. Define whether the launch tick counts, whether
completion occurs before or after the Nth decrement, and the exact ordering of
sanity, `_post`, state publication and watchdog eligibility. For the relay, prove
both a lower bound above the datasheet minimum and a safe upper bound. Across all
targets, include oscillator tolerance, the code-position offset between `_pre`
and `_post`, and worst-case loop execution time. A latched one-bit tick indication
cannot recover elapsed ticks if main falls behind; delayed or coalesced service
must be shown to lengthen safely rather than shorten the pulse, and the ordinary
loop must remain below one tick in every active-state path.

---

## 6. The PIC10F320: the minimal shape fits

The obvious expectation is that the most flash-constrained part in the project is
the one that cannot fit even the minimal countdown shape. That expectation is
wrong twice over, and both resource reversals are measured below. §7 separately
shows that fitting the shape is not the same as fitting a complete safety policy.

Everything in this section was built with the same pinned XC8 and DFP as §2,
invoked as the Makefile invokes it. The baseline reproduces
`make pic10f320` exactly (220 / 241 / 244 words), which is what makes the deltas
trustworthy.

### 6.1 Why this part asks a different question

`src/bypass_mcu_pic10f320.c` is architecturally unlike every other shell —
`docs/pic10f320_special_case.md` is the authoritative statement of why. Three of
its properties change the shape of this question:

- **It links none of `src/bypass_output_*.c`.** Its output stages are
  source-local static functions selected by `#if defined(OUTPUT_*)`. So §5.4 does
  not reach it: converting the shared drivers changes nothing here, and this part
  must be converted by hand.
- **It uses no interrupts at all.** There is no `__interrupt` handler and `GIE` is
  only ever cleared. So unlike §2, its resource feasibility is a flash question
  with no return-stack question hiding behind it (confirmed in §6.5). The wider
  safety question is not resource-only.
- **It has 256 words, and 12 of them spare** on the variant that blocks longest.

### 6.2 The measurement

Three builds of each variant: the shipping source, the two-function API from the
earlier §3.2, and the four-function `_pre`/`_post` API with the countdown guarded
by `#if (ACTUATION_TICKS > 0U)` (the file-local spelling of
`BYPASS_ACTUATION_TICKS` on this self-contained shell).

| Variant | Shipping | 2-fn `begin/end(target)` | 4-fn `_pre`/`_post` | Spare, 4-fn |
|---|---|---|---|---|
| `cd4053_simple` | 220 (85.9%) | 240 (+20) | **220 (+0)** | 36 |
| `cd4053_with_mute` | 241 (94.1%) | **does not link** | **249 (+8)** | 7 |
| `tq2_l2_5v_relay` | 244 (95.3%) | 252 (+8) | **252 (+8)** | 4 |

Two things fall out of this table.

**The four-function form is free where there is nothing to defer.**
`cd4053_simple` compiles to the same 220 words as the shipping source. With
`ACTUATION_TICKS` at zero the `#if` removes the countdown and the state byte, and
the variant needs no `_post` half at all — what remains is today's code with two
functions renamed. That is the clearest available evidence that the scheme's cost
is the *deferral*, not the API.

**The two-function form is not affordable.** It costs 20 words on the variant with
no delay to refund, and overflows `cd4053_with_mute`. This is the §3.2 correction,
and this part is where it was caught — because it is the only part with no room to
absorb a mistake of that size.

The +8 words on the two blocking variants is a net figure: the deferral machinery
costs more than +8, and deleting `__delay_ms()` and its wrapper refunds the
difference. Both variants land on the same +8 because the refund is the same
size on both — XC8's generated delay loop does not grow with the constant in this
range. Rebuilding the shipping mute variant with `CD4053_MUTE_DELAY_MS` forced
from 5 to 12 produces the same 241-word footprint, so the 12 ms coil pulse and the
5 ms mute gap cost exactly the same flash today. The executable bytes necessarily
differ because the generated delay duration differs.

### 6.3 The §5.1 latch-check cost is zero here

§5.1 identified the sanity checks learning transient output states as a major
unpriced flash cost. On the PIC10F320 that specific latch-check cost does not
arise.

`hw_is_sanity_check_failed()` in this shell resolves, in every variant, to
`hw_output_pins_intact()` — an exact `TRISA` comparison. It checks pin
**directions**, and directions do not change during an actuation. There is no
output-latch assertion to teach direction-specific transient states to.

The reason is recorded in `docs/pic10f320_special_case.md` §4: the full
output-latch match is **deliberately omitted on this part** for flash, and is the
one defensive check the PIC10F322 carries that the PIC10F320 does not
(`hw_output_state_intact()`).

So the expected ordering inverts locally: **the most constrained part pays no
incremental cost to adapt a latch check, precisely because it already gave that
check up.** That is a real finding, but it should be read carefully. It does not
mean the PIC10F320 solved a problem the PIC10F322 has — it means the PIC10F320
already paid for this, in a different currency, and the receipt is filed under a
different heading.

It has one forward-looking cost. §4 of the special-case document records the
latch check as priced-and-rejected, not as unwanted. Under non-blocking actuation,
re-adding it would also require direction-specific transient semantics. That
formulation is not priced here and is not affordable within the measured current
headroom unless space is recovered. Conversion therefore makes future latch-check
restoration a harder, explicit resource decision rather than silently proving it
impossible.

### 6.4 What does not fit: range-checking the new state

The project's defence-in-depth idiom range-checks every element of `ctx_` in the
main-loop sanity gate. A new `actuation_ticks_` byte invites the same treatment:
`(actuation_ticks_ > ACTUATION_TICKS)`.

Its cost is **+4 words** on each variant that has a countdown to guard, and zero
on `cd4053_simple`, where the same `#if` removes it along with the state it
guards. The relay figure is measured on the relay rather than extrapolated from
the mute variant: since the guarded relay build does not link, an unrelated 4-word
check was ablated to create headroom and both relay builds re-linked (248 → 252).

| Variant | 4-fn, no range check | 4-fn + range check |
|---|---|---|
| `cd4053_simple` | 220 (36 spare) | 220 (36 spare) — `#if`-elided |
| `cd4053_with_mute` | 249 (7 spare) | 253 (3 spare) |
| `tq2_l2_5v_relay` | 252 (4 spare) | **256 — does not link** |

The relay lands on exactly 256 words, and fails with the same mechanism §2.2
documents for the PIC10F322 ISR build:

```
error: (1347) can't find 0x2 words (0x2 withtotal) for psect "text16"
in class "CODE" (largest unused contiguous range 0x1)
```

Not "slightly too large" — exactly at budget and unlinkable for want of two
contiguous words.

That leaves three options, none free:

1. **Ship the state unguarded**, and record a second deliberate omission on this
   part alongside §4's.
2. **Guard it on two variants and not the third.** `docs/pic10f320_special_case.md`
   §4 already considered and rejected a per-variant defensive layer, for reasons
   that apply unchanged here: the fault harness and mutation topology would need
   per-variant expected counts, and the documentation gains a three-way split
   instead of one clean statement.
3. **Find 4 words elsewhere**, which means reopening exactly the trade §2 and §9
   conclude against.

This is the decision this section exists to surface. It is the difference between
"fits" and "does not", and it should be settled before any code is written rather
than discovered at link time.

### 6.5 The return stack does not move

Both oracles of `test/check_stack_depth_pic.sh` — the emitted instruction stream
and XC8's own `callstack` directives — agree, and agree with the shipping
baseline:

| Variant | Shipping | 4-fn non-blocking | Reserve | Spare |
|---|---|---|---|---|
| `cd4053_simple` | 3 | 3 | 2 | 3 |
| `cd4053_with_mute` | 3 | 3 | 2 | 3 |
| `tq2_l2_5v_relay` | 4 | 4 | 2 | 2 |

The independent HEX-based oracle (`test/pic10f320/return_stack_oracle.py`)
produces the same witnesses. Splitting one actuation function into two does not
deepen the graph: the `_pre` half inherits the chain the original had, and the
`_post` half is shallower.

### 6.6 What conversion buys on this part specifically

**It closes a divergence the equivalence lane structurally cannot see.** The host
mock routes `__delay_ms()` to `bypass_on_delay_ms()`
(`test/pic10f320/equiv/xc.h`), a hook that consumes **zero ticks**. So the host
model and real silicon disagree today about post-toggle timing — the device loses
about 12 ticks to the coil pulse, the model loses none — and
`pic10f320-test-equiv` compares state transitions, not elapsed ticks, so it cannot
observe the difference. The timing lanes accommodate it instead, by widening
stimulus holds by the block length. Non-blocking actuation can make the tick count
explicit state that the host models exactly once §6.7's observation seam is
replaced, converting an accommodated divergence into a checked one.

**It removes this part from the timing caveat.** The PIC10F320's special-case
status is *architectural* — the hand-inlined core — not temporal. Nothing about
256 words forces its debounce sampling/re-arm timing to differ from every other
target. A uniform accepted-tick model across the entire matrix, PIC10F320
included, is therefore achievable, which is a stronger version of the goal than
§1 assumed was on the table. Physical pulse widths remain bounded per shell.

### 6.7 What conversion costs on this part specifically

- **The new state falls outside the automated equivalence gate.**
  `pic10f320-test-equiv` steps the real firmware against the real
  `src/bypass_pure.c` and compares `ctx_`. `actuation_ticks_` is shell-local, so
  nothing compares it to anything. It joins the manually-synced surface.
- **The equivalence gate's observation clock also disappears while active.** The
  host harness advances stimulus and records `ctx_` and `LATA` from its
  `CLRWDT()` hook. Withholding the pet across actuation means that hook does not
  run for 5 or 12 healthy loop iterations. The current lane would skip the new
  state rather than merely fail to compare it. It needs an unconditional
  end-of-serviced-tick hook independent of watchdog eligibility.
- **The shared-surface table gains a row.**
  `docs/pic10f320_special_case.md` §5 enumerates every item this part must keep in
  step by hand. Actuation timing becomes one, and the table is explicitly "the
  checklist for what to edit, not the mechanism that catches you forgetting".
- **The pulse width stops being exact.** `_post` runs at the top of the loop body
  and `_pre` near the bottom, so a 12-tick countdown yields 12 ms *minus* the part
  of the loop body between them — of order 0.1–0.2 ms at 2 MHz, estimated from the
  instruction count and **not measured** (§6.8). That leaves roughly 3× the
  TQ2-L2-5V's 4 ms datasheet minimum either way, and loading one extra tick makes
  it exact-or-longer, but `pic10f320-test-io` measures pulse widths from simulator
  cycles. Its existing expected value and ±0.2 ms tolerance would need review and
  likely rebaselining for the new path-dependent width.
- **`CLRWDT` is also the real-HEX lock-step and fault-injection seam.** The shared
  PIC lock-step identifies the repeated loop pet behaviorally and treats it as a
  completed iteration; the fault harness parks there so an injected value is read
  by the next sanity gate. Neither can observe or inject a healthy active tick
  once the pet is withheld. New symbol/breakpoint plumbing is required on both PIC
  parts, not only in the PIC10F320 host harness.
- **Baselines move.** `test/pic10f320/expected_images.sha256` needs an intentional
  rebaseline, and the actuation, I/O and soak lanes all re-baseline with it.
- **Four spare words on the relay variant** is a thin place to live, on a part
  whose documentation already turns on 1-word and 4-word decisions.

### 6.8 Scope of this section

These are flash and return-stack figures. The spike was compiled, budget-gated and
stack-gated; **it was not run**. No actuation, lock-step, I/O, fault or soak lane
was executed against it, and no claim is made here about its behaviour — only
about whether the shape fits the part.

---

## 7. The relay coil: a safety property the redesign silently drops

Every section above treats this as a resource question. It is also a hardware
safety question, and on the relay variant that is the more serious of the two: the
TQ2-L2-5V's coils are pulse-rated, and leaving one energized is a way to destroy
the part rather than merely misbehave.

The concern that opened this section was an intuition — that the blocking form
"feels" safer because *energize, wait, de-energize* is verifiable in four
consecutive lines, while the non-blocking form spreads the same obligation across
a dozen loop iterations and a RAM byte. That intuition is correct, and the reason
is more specific than the surface area.

### 7.1 What the blocking form guarantees without saying so

The PIC loops pet at the end of the completed iteration; the AVR loops pet before
`debounce_step()` and any resulting actuation. In either ordering, **no pet occurs
between coil energization and de-energization.** Any fault that strands the CPU
mid-pulse — a corrupted PC, a hang in the delay loop — withholds the next pet by
construction and is bounded by one watchdog period.

Nobody designed that. It falls out of where the pulse sits relative to the pet.
But it is a real property, and it is load-bearing.

Under non-blocking actuation the pulse spans twelve *complete* loop iterations,
and every one of them reaches `CLRWDT()`. The watchdog is being fed, on schedule,
by a loop that is doing exactly the wrong thing. **The coil-on window goes from
watchdog-bounded to unbounded**, and nothing in §3 through §6 notices.

### 7.2 The dangerous failure is the counter reaching zero early

The obvious fear is an upset that raises `actuation_ticks_`, stretching the pulse.
The worse one is the opposite.

`_post()` fires only on the 1 → 0 transition of the countdown. An upset that
*clears* the counter while a coil is energized means that transition never
happens: the de-energize never runs. On PIC10F320 the loop remains perfectly
healthy, the direction-only sanity gate sees nothing wrong, and the coil stays
energized indefinitely. A full shell with the exact phase-aware latch check from
§5.1 can detect coil-high/idle disagreement on the next tick, but without §7.9's
abort it still preserves the coil until watchdog reset.

Note what this does to §6.4. The range check priced there tests
`actuation_ticks_ > ACTUATION_TICKS` — it catches too-high and is blind to
too-low. The defensive check that did not fit would not have covered the worst
case anyway, which weakens the argument for buying it at the expense of something
else.

### 7.3 Two mitigations, and the PIC10F320 relay affords one

Both were built and measured on the relay variant, on top of the four-function
non-blocking build from §6.2 (252 words, 4 spare):

| Build | Relay words | Spare |
|---|---|---|
| non-blocking, no mitigation | 252 | 4 |
| **+ re-assert the safe resting state when idle** | 254 | 2 |
| **+ withhold the pet during actuation** | 255 | 1 |
| + both, as two separate tests | — | **does not link** |
| + both, merged into one `actuation_ticks_ == 0` test | — | **does not link** |
| + the §6.4 range check | — | **does not link** |

**Withholding the pet** restores §7.1's property while active state remains
correctly represented:

```c
#if (ACTUATION_TICKS > 0U)
        if (0U == actuation_ticks_)
#endif
        {
            CLRWDT();
        }
```

The longest healthy un-petted span becomes one tick plus the pulse — 13 ms —
which is precisely what the existing PIC10F320 local mute/relay assertions already
guarantee:

```c
static_assert((TICK_PERIOD_MS + TQ2_L2_5V_PULSE_MS) < WDT_MIN_PERIOD_MS, ...);
```

The modular shells do not currently carry the equivalent WDT-period assertion in
their shared drivers; a redesign should add per-target compile-time bounds rather
than treating the PIC10F320 assertion as project-wide.

That is a third assertion this redesign promotes rather than retires (compare
§5.2). Withholding makes a stalled or sufficiently prolonged counter observable
to the watchdog, but it does **not** subsume §6.4's range-check semantics. A
one-time in-range or slightly high value can count down normally before the
watchdog expires, especially at the watchdog's slow extreme; the range check
would detect an out-of-range value immediately while withholding alone would not.

**Re-asserting the safe resting state on every idle tick** covers §7.2 for the
relay. It is a per-driver notion. The measured spike used "both coils low" for
the relay and an empty operation for the x4053 variants because they have no
energized-coil hazard:

```c
#  define ACTUATION_IDLE() set_relay_coils_low()   /* relay      */
#  define ACTUATION_IDLE() /* nothing pulses */    /* both x4053 */
```

It must be a **macro, not a function**. As a function it costs +3 words on
`cd4053_with_mute` for an empty body the compiler does not elide, and the relay
build does not link at all; as a macro the analog-switch variants pay nothing and
the relay pays 2.

The empty x4053 hook is adequate only for this relay-energy measurement. It is
not a complete output-liveness policy: §7.12 shows that an early-zero counter can
strand the muted variant in `(0, 1)`, so that variant needs its own settle or
reconcile behavior priced separately.

**Neither subsumes the other.** Withholding the pet bounds the coil-on time from
above but does nothing about a counter stuck at zero, because the pet resumes the
moment it reaches zero. The idle re-drive fixes stuck-at-zero but does not bound a
counter stuck high, because the loop keeps petting throughout. Together they are
complete for these two countdown-stall cases; on the PIC10F320 relay variant they
do not fit, including when merged into a single comparison at the end of the loop
body to share the test.

The original recommendation treated "affords exactly one" as a policy choice and
selected the withheld pet. That is too weak for this project's stated bar. Each
single-mitigation build retains an unbounded energized-coil path; choosing which
one remains unbounded does not turn the result into reference-quality firmware.
The measured table establishes that this particular pair of source formulations
does not fit. It does **not** establish that an equivalent complete formulation
cannot fit — for example, a relay-specific service operation might use the
physical coil-latch pattern to recognize and settle a zero-count active state
before deciding whether a pet is legal. That alternative is unmeasured.

The acceptance rule should be simple: the PIC10F320 relay converts only if a
measured implementation covers both too-high/stalled progress and prematurely
idle progress. If no complete formulation fits, keep its relay actuation blocking
even if other targets or output variants convert. Uniform timing is subordinate
to bounded hardware energy.

### 7.4 The blocking form is not as safe as it feels

The intuition holds for the *pulse* and fails for the *steady state*.

If an SEU sets a coil bit in `LATA` after the pulse has completed, the PIC10F320
re-drives `LATA` only on a debounced press. `docs/pic10f320_special_case.md` §4
states the consequence directly: the upset "persists — wrong LED, wrong signal
path, or both — until the next footswitch press re-drives the outputs." For the
relay that is an unbounded energized coil, in shipping firmware, today.

Spelled out electrically, the relay's stable firmware state has both RA1/RA2 coil
driver latches low. A post-actuation upset that sets either bit high can turn the
corresponding external coil driver on even though `ctx_.effect_state`, the
debounce machine, TMR2 and the watchdog are all healthy. PIC10F320 validates the
pin directions but deliberately does not compare `LATA` with the expected stable
mask. Its unconditional trailing `CLRWDT()` therefore continues forever, and no
software event rewrites the coil bit until the next accepted press. This is not a
failure of the blocking delay and non-blocking actuation is not required to fix
it; it is the direct consequence of omitting both stable-latch validation and an
idle safe-state rewrite.

On the PIC10F322 it is caught: `hw_output_state_intact()` compares the exact latch
against the expected mask every tick and forces a watchdog reset. That is the one
defensive check the PIC10F320 omits for flash — the same omission that made §6.3
cheap. It cuts both ways, and here it cuts against the current design.

"Caught" still means bounded by reset, not immediately de-energized. The current
PIC10F322 and AVR fault functions enter a watchdog-reset spin without first
changing output drive, so a latch upset that energizes a coil can remain active
for the remaining watchdog interval, potentially almost a complete period.
Whether that interval is thermally safe is the same unanswered hardware question
as §7.8. An explicit fault-abort operation would improve the blocking firmware
too.

So the idle re-drive from §7.3 would **close an existing hole**, not merely
contain a new one. On this specific axis, non-blocking actuation plus a 2-word
mitigation is safer than what ships now.

The improvement should not be held hostage to the architectural decision. The
same relay-only idle coil-low re-drive can be evaluated as an independent change
to the current blocking PIC10F320 firmware, where the relay image has 12 spare
words rather than the non-blocking spike's four. Rejecting or deferring the
non-blocking redesign is not a reason to leave this existing unbounded path in
place.

The reset path itself is sound under either scheme, and is worth stating because
the rest of the argument leans on it: `TRISA` returns to inputs on reset, removing
drive from the coil pins regardless of `LATA`, and `init()` then drives `LATA` low
*before* restoring the output directions — so recovery de-energizes the coil and
does not glitch it on the way back up.

### 7.5 What the watchdog is, and is not, a backstop for

It is tempting to treat abnormal conditions as beyond reach — extreme EMI, thermal
excursion, "all bets are off, hope the watchdog resets us." That is half right,
and the half that is wrong matters here.

The watchdog backstops a **hung** CPU. It does not backstop a loop that is running
correctly, passing every sanity check, petting on schedule, and holding a coil
energized. That is precisely the state §7.1 and §7.2 describe, and it is reachable
only because the redesign moved the pulse to the fed side of the pet.

So "hope the watchdog triggers" is not a fallback this design gets for free. It is
a property that currently exists by accident, that the redesign removes, and that
the measured PIC10F320 spike spends 3 words to restore while active state remains
correctly represented. Premature zero still resumes pets with an energized coil;
complete restoration also needs the separate idle/early-zero protection in §7.3.

### 7.6 It is provable, but the existing harness seams must move

Both failure modes fit the *roles* of the PIC10F320's existing lanes, but not
their current observation mechanics:

- **Counter stuck high** belongs in the fault lane and must produce exactly one
  real watchdog reset. The current harness, however, parks injections at the
  loop's `CLRWDT`; a design that withholds that instruction while active provides
  no such breakpoint inside the window being tested.
- **Counter cleared mid-pulse** belongs in the actuation lane: corrupt the counter
  while a coil is energized, and assert both coils are low within one bounded
  service interval. The current host actuation seam is the `__delay_ms()` hook,
  which disappears with the blocking call.

The tests therefore need a watchdog-independent end-of-serviced-tick boundary
and an explicit active-state injection point. This is a plumbing change rather
than a missing test concept, but it is essential: otherwise the lanes can remain
green while skipping all 5 or 12 transitional iterations.

`actuation_ticks_` only becomes a useful fault-injection target if its corruption
has an observable response. With §6.4's range check unaffordable, withheld pets
make stalled or sufficiently prolonged progress observable; an idle reconcile or
exact latch/state invariant must separately make too-low progress observable.
Short out-of-range excursions that complete before timeout remain a distinct
detection gap.

### 7.7 This qualifies §4's strongest argument

§4 argues that non-blocking actuation would permit a materially shorter watchdog
period on both families. Withholding the pet across deferred actuation constrains
rather than eliminates that opportunity. A one-tick watchdog is unavailable: the
minimum tolerated period must exceed the longest healthy actuation plus WCET,
clock/watchdog tolerance and design margin. A period materially below 250/256 ms
can still satisfy that inequality, and would improve the upper bound on a stalled
output state.

The relay therefore turns watchdog tightening from a free consequence into a
sizing exercise. Coil-energy containment takes priority, and §7.8 still has to
establish that the selected worst-case timeout is itself safe. The muted variant
has the same output-liveness reason to withhold pets across its shorter 5 ms
window, without the relay's thermal consequence; the simple variant has no
deferred interval at all.

### 7.8 What is not established here

- **Whether the PIC10F322 affords both mitigations.** It has 39 spare words on the
  relay variant against the PIC10F320's 12, and the mitigations cost 2 and 3 words
  respectively on PIC10F320, so it very likely does — but that is an inference
  from a different part, not a measurement, and the PIC10F322 spike was not built.
- **What the TQ2-L2-5V actually survives.** Everything above reasons about
  *bounds* — unbounded versus one watchdog period. It does not establish what the
  coil tolerates thermally at the PIC's ~160–430 ms worst-case watchdog window;
  AVR extrema are target-specific. This is a datasheet and bench question the
  document has not answered. Until the applicable bounds are known, withholding
  the pet is a necessary software bound and not a proven hardware-safe bound.

### 7.9 A sanity fault during the pulse needs immediate abort

Blocking actuation does not run the main-loop sanity gate between energize and
de-energize. Non-blocking actuation deliberately does. That improves detection,
but changes the required fault response: any unrelated context, pull-up, clock,
timer, direction or output-latch fault can now be detected while a relay coil is
high.

Every current `hw_force_wdt_reset()` disables interrupts and spins. None changes
the outputs first. Calling it directly from an active tick therefore preserves
the coil's current electrical condition until hardware reset, potentially nearly
the target's full watchdog period rather than only the remainder of the intended
12 ms pulse. On the PIC that full-period range is approximately 160–430 ms; AVR
bounds are target-specific. The reset sequence then safely removes drive as §7.4
describes, but it is too late to call the entry path fail-safe without the relay's
thermal bound.

The redesign needs a target-specific `abort`/safe-output primitive before the
reset wait. For the relay its postcondition is physical removal of both coil
drives, not merely an attempted latch write. Direction corruption, AVR-XT pin
inversion and the external driver topology must be included in deciding whether
low latches, input/high-impedance direction, or both are required. For the muted
analog switch, the policy should explicitly choose fail-muted or immediate
BYPASS before reset. The fault lanes should inject every guarded fault at every
active tick and assert the physical relay pins become inactive within a fixed
instruction/tick bound.

This primitive could improve today's blocking design too: §7.4's post-actuation
latch upset is detected on the full shells, but their present fault path waits for
reset before removing the resulting drive.

### 7.10 The tick source becomes safety-critical

Today's `__delay_ms()` / `_delay_ms()` sequence is driven by CPU instruction
execution. Once a coil is energized it reaches `set_relay_coils_low()` even if
the target's tick timer (PIC TMR2, AVR Classic Timer0 or AVR-XT TCB0) stops. The
non-blocking sequence makes that timer responsible for de-energization.

Two opposite failures matter:

- **Stopped tick.** At runtime, the coil remains high until the withheld watchdog
  resets the part. During the proposed asynchronous startup, reset begins another
  RESET pulse; if the tick is still dead, the system can repeat watchdog-length
  pulses separated only by reset/init overhead. In each reset cycle current
  firmware instead produces one 12 ms startup pulse, parks both coils low, and
  spends the remainder of the watchdog interval waiting for the dead tick.
- **False-fast tick.** A PIC `TMR2IF` that repeatedly appears set can make the
  polled loop consume twelve logical ticks at CPU-loop speed, settle the coil too
  early and resume normal pets. The existing SFR checks prove `PR2` and `T2CON`
  retain their configured values; they do not prove elapsed time between flags.
  The AVR ISR/main handshake likewise proves ordinary liveness, not an independent
  lower bound on timer cadence.

Oscillator tolerance is already included in ordinary pulse qualification, but a
faulted tick is a different case. Acceptance needs stopped-tick, one-spurious-tick
and persistent false-fast-tick tests or a reasoned hardware exclusion. Startup
should not energize a relay until timer progress has been demonstrated, and the
watchdog-bound pulse must independently be shown safe for the relay. This is the
largest architectural disadvantage not captured by a flash figure: the tick
timer moves from debounce infrastructure into the hardware-energy safety case.

### 7.11 Range checking does not protect valid-but-wrong state

`actuation_ticks_ > ACTUATION_TICKS` detects only one class of corruption. It
cannot detect zero written early or a smaller in-range value. For example, the
relay's initial 12 is binary `0b1100`; clearing bit 3 produces a valid value 4.
Four nominal ticks at the documented +10% fast-clock extreme are about 3.64 ms,
below the relay's 4 ms minimum. The current 3× timing margin therefore does not
automatically survive a single in-range bit clear in the new state byte.

The same principle applies outside the counter. A valid one-bit change from
`RELEASE_DEBOUNCE_WAIT` to `PRESS_DEBOUNCE_WAIT` can cause a second toggle while
the release counter is still above `PRESSED_THRESH`, and a valid
`effect_state` change can redirect which `_post` half is selected. Existing range
checks deliberately cannot reject another valid enum value.

This does not imply that every valid-state SEU needs duplicated RAM. It does mean
the new state should be selected and encoded with fault effects in mind, and the
complete one-bit/value fault matrix should be tested. Options to price include a
duration/encoding whose downward single-bit errors retain the relay minimum, a
redundant or complemented active marker, and a latch/state invariant that uses
the active physical output as evidence that `_post` is still owed. None is
measured here.

Write ordering is the minimum no-cost requirement: publish active before `_pre`
can energize an output, and perform `_post` before publishing idle. It does not
solve instruction skips or every RAM upset, but it avoids creating an ordinary
window in which the watchdog policy sees idle while hardware is still active.

### 7.12 The muted variant has the same liveness shape

The relay makes the early-zero failure safety-critical, but it is not the only
variant affected. During a runtime transition, the muted driver's `_pre` leaves
`(CTL1, CTL2) = (0, 1)` and `_post` performs the final unmute. If the countdown is
cleared and completion is triggered only by the 1 → 0 transition, `_post` never
runs. Startup BYPASS is the separate all-low case described in §5.1.

On the full shells, an exact steady-state output check can notice the mismatch
once the counter says idle, provided §5.1's phase-aware check is implemented; the
fault-abort policy still determines what happens before reset. PIC10F320 has no
output-latch check. With an empty x4053 idle hook it can remain muted indefinitely
while executing and petting normally. That is a functional outage rather than
hardware damage, but it fails the same liveness obligation: every accepted
actuation must reach its requested settled state in bounded time.

PIC10F320 mute therefore also needs a priced idle settle/reconcile operation or a
state encoding that cannot lose the owed `_post`. The relay-only 2-word result in
§7.3 does not price this requirement.

### 7.13 Validation must observe output progress independently of the watchdog

The current PIC test architecture intentionally uses `CLRWDT` as a behavioral
landmark. Real-HEX lock-step treats the repeated loop pet as "iteration complete";
PIC10F320 host equivalence records `ctx_`, `LATA` and advances input from its
`CLRWDT()` mock; fault injection parks at the same instruction so the next sanity
gate deterministically sees the corruption. Withholding the pet is production
behavior, so tests cannot insert a synthetic pet merely to preserve those seams.

Both PIC shells need a watchdog-independent end-of-serviced-tick observation
point. The output model compared there should include active/idle, target,
remaining ticks and exact phase-dependent pins. The pure debounce proofs remain
valid, but they do not prove this product state. A small independent output-FSM
specification can exhaustively prove:

- legal phase/count combinations and active/idle consistency;
- relay coil exclusion and exact direction;
- exclusion of the invalid x4053 `(1, 0)` combination;
- no early completion and bounded eventual completion under accepted ticks;
- startup serialization and active-request fault handling;
- settled outputs agreeing with `ctx_.effect_state`.

Built-image lanes must still establish what the abstract model cannot: real edge
ordering, cycle-level lower/upper pulse width, startup behavior, physical port
following the latch, watchdog withholding, fault abort and reset recovery. The
mutation set should include `N-1`/`N+1` loads, missing decrement, missing `_post`,
idle published early, wrong direction, duplicate request, active sanity
suppression and both countdown-zero/high corruption.

### 7.14 Secondary gains and behavior changes

Several smaller advantages remain real after the safety corrections:

- AVR main can return to IDLE sleep between actuation ticks instead of executing
  a 5/12 ms busy delay, reducing busy-loop execution and CPU active time. Any
  corresponding supply-current/noise improvement is expected but unmeasured.
- The PIC host model no longer treats a real multi-millisecond delay as consuming
  zero model ticks; output progress becomes inspectable state.
- The PIC accepts release samples during actuation, making its re-arm behavior
  match the AVR and improving its conservative repeat-tap budget by up to the
  5/12 ms block. The retained pending timer flag normally makes the exact
  difference roughly one accepted sample smaller, with phase and overhead also
  contributing.
- Exact active-state checks can detect output faults during the pulse rather than
  waiting until an atomic call returns.

The third item is also a compatibility change: a tap previously too fast for the
PIC's blocking-extended lockout can become accepted. It is desirable under the
project's fast-tap goal, but it should be documented and qualified as changed
behavior rather than described only as cleanup.

---

## 8. Related historical finding: the old call lexer rejected an ISR build

Discovered while taking the §2.3 measurements. The initial `i1_` recognition fix
landed in `56ad068`; `084ae09` later removed the prefix assumption and hardened
the complete direct-call/psect parser. Neither commit measured a PIC12F675 ISR
stack result.

`test/check_stack_depth_pic.sh` built its call graph from targets matching:

```awk
/^[ \t]+(fcall|call|lcall|pcall)[ \t]+_/
```

XC8 names the copies it makes of a non-reentrant function reachable from two call
graphs `i1_<name>` / `i2_<name>` (advisory 1510) — with no leading underscore.
Those appear the moment an ISR shares a helper with `main()`, which is exactly
what an ISR shell does. The edge into the duplicate was dropped, leaving it with
no callers, and the root-versus-entry cross-check rejected the build with:

```
FAIL: i1_hw_read_footswitch is never called but XC8 does not list it as an
entry point
```

Three things are worth recording about this:

- **It never affected shipping firmware.** There is no `__interrupt` handler in
  either PIC shell and no `GIE = 1` anywhere, so XC8 never emitted a duplicate.
  Every call target inside a function psect in all three built images starts with
  `_`, and all three measure correctly (3 / 3 / 4 levels).
- **The observed `i1_` case failed structurally, but that was not a general
  guarantee.** This duplicate had its own XC8 function annotation, so dropping
  the edge left an uncalled annotated function that was not an entry point. An
  unrecognized target with no annotation could instead disappear before the
  structural checks and lower the measured depth.
- **The gate's analysis was already right.** It sums the reset and interrupt
  trees and adds the hardware-pushed return address, and `test_stack_depth_pic.sh`
  case 11 already covered ISR summing. That case passed because its synthetic
  helper is spelled `_ihelp`; only the lexer had not been told what real XC8
  emits.

The initial fix admitted `i[0-9]+_`; the gate now removes the prefix assumption
entirely. It records every direct `call`/`fcall`/`lcall`/resolved `pcall` inside a
validated function psect and requires the target to have an XC8 function
annotation. Startup helpers such as `clear_ram0` remain allowed only outside
function psects. Regression case 12 uses the real `i1_` spelling, while separate
fixtures prove arbitrary unprefixed targets cannot disappear from the graph.

That change carried its own instance of the same lesson, and it is worth being
blunt about it. Deciding "inside a function psect" meant reading `psect`
directives, and the new rule ended the current function at every one of them.
XC8 re-selects a function's own psect *inside* its body — once immediately after
the `;psect for function` marker, and again to restore the psect after every
inline-asm escape (`clrwdt` in the PIC shell):

```
psect	text1,local,class=CODE,delta=2,merge=1,group=0
global __ptext1
__ptext1:	;psect for function _init
psect	text1              <-- re-selection; still inside _init
_init:
	fcall	_hw_wdt_pet
```

Every body in every real image therefore parsed as being outside any function
psect, and the gate rejected all three PIC10F322 variants. The synthetic
fixtures did not catch it because they emitted a bare marker with no psect
scaffolding at all — the same gap as case 11's `_ihelp`, one layer down: a
fixture that is *shaped* like XC8 output only proves what its shape covers. The
gate now binds each function to the psect it was declared in and treats a
re-selection of that psect as staying inside the body, while any other psect
still ends it. The fixture builders emit the full declaration/marker/re-selection
sequence, so every case exercises it, and dedicated cases cover the inline-asm
restore, a genuine mid-body psect switch, and a marker that would otherwise
inherit the preceding function's psect.

---

## 9. Recommendation

**Do not trade self-health checks for an ISR on the PIC10F322.** The purchase
price is a 511/512-word image with 0 of 8 stack levels spare on the relay
variant — flash effectively exhausted and zero stack margin beyond the deliberate
two-level reserve — to remove a small, non-audible but repeat-tap-observable timing
difference. For firmware whose stated goal is textbook-grade reference quality,
that is the wrong place to spend the last of two budgets at once. Dropping the
`ctx_` range checks specifically is backwards under an ISR, since `ctx_` becomes
state shared across two execution contexts and is *more* exposed, not less.

**If uniform timing is worth pursuing, non-blocking actuation is the better
instrument.** It attacks the PIC sampling divergence at its source, makes output
progress explicit and permits the same accepted-tick model on every platform. It
also moves the relay completion guarantee onto the tick timer and a RAM state
machine. The accurate conclusion is not "clean win" but **promising normal-timing
simplification with a larger safety proof obligation** (§4, §7).

**Keeping the current blocking design is a defensible outcome.** The observable
benefit is an improvement of up to the 5/12 ms block in the PIC's conservative
re-arm budget after a toggle, normally reduced by the one pending timer sample;
it is not lower initial press latency or an audible switching change. The current
output transaction is small, timer-independent once started, and already heavily
qualified. Uniformity is valuable, but it does not justify a known incomplete
hardware-safety policy.

**The next step is a safety/feasibility spike, not an implementation.** The
PIC10F322 transient-state flash price remains necessary and is no longer the only
gate. A decision-quality spike must establish all of the following before a
shipping conversion starts:

1. Exact direction-aware active-state sanity checks fit the PIC10F322 relay and
   mute variants without suppressing latch validation.
2. Startup is serialized, with a press beginning at every startup tick unable to
   overlap or truncate the initial relay RESET pulse (§5.3).
3. The orchestrator publishes active before `_pre`, settles before publishing
   idle, rejects a request while active and has an explicit wrong-state policy
   (§5.5).
4. Every fault detected during actuation removes physical relay drive before the
   watchdog-reset wait (§7.9).
5. Stopped, spurious and false-fast tick behavior is bounded, and the relay's
   worst watchdog-length pulse is proven electrically/thermally safe (§7.8,
   §7.10).
6. Zero, high, every in-range countdown value and every single-bit countdown
   corruption preserve the required minimum/maximum pulse policy or cause bounded
   recovery (§7.11).
7. The muted variant cannot remain indefinitely in `(0, 1)` after lost progress
   (§7.12).
8. PIC lock-step, equivalence and fault injection use a watchdog-independent tick
   boundary and compare/inject the complete output state (§6.7, §7.13).
9. Built-image timing establishes cycle-level lower and upper pulse bounds, and
   active-path worst-case execution remains below one tick on each shell.
10. The exact spike sources are retained long enough for independent rebuild and
    review; prose reproduction steps are useful evidence and not a substitute for
    reviewing the implementation whose size is being accepted.

**Use the four-function `_pre`/`_post` interface, not a parameterised pair.**
This is settled by measurement rather than taste (§3.2, §6.2), and getting it
wrong is not a style regression — the two-function form is unaffordable across
the matrix and the mute variant does not link. Keep all four primitives behind
one orchestrator so the compiler-motivated interface does not become a generally
callable protocol.

**The PIC10F320 should be the last target converted, not the first.** §6
establishes that the minimal shape fits at +8 words on each delayed variant and
that adapting a nonexistent latch check costs nothing. Neither is a reason to
start there. It has 4 spare words on its relay variant, no automated gate covering
the new state (§6.7), and a defensive-layer decision to settle first (§6.4).
Prove the design where being wrong is
recoverable — a host output-FSM model and the roomier AVR parts, then the
PIC10F322 — and port it here once the shape has stopped moving. Two of the
findings in §6 were only visible *because* this part has no margin; that makes it
an excellent validator and a poor prototype.

**Withhold the watchdog pet across every deferred actuation, but do not mistake
that for a complete mitigation.** It makes stalled or sufficiently prolonged
output progress observable; the relay makes this hardware-safety-critical. It
does not detect every high value, does not handle premature idle, changes the test
boundary, and can leave a relay active for nearly a watchdog period that is not
yet proven safe. Idle/early-zero recovery and immediate fault abort are separate
requirements (§7.3, §7.8–§7.13).

**Do not convert the PIC10F320 relay with only one of the §7.3 mitigations.** The
measurement "exactly one fits" means the measured formulation is incomplete, not
that the project should select which unbounded failure to retain. Find a complete
equivalent formulation, free enough words without weakening another defensive
layer, retain blocking relay actuation on this target, or do not support that
target/variant combination under the new architecture.

**Address the existing PIC10F320 relay latch-upset hole independently.** A
relay-only idle coil-low re-drive closes a current unbounded failure and was
measured at 2 words in the non-blocking spike; the current blocking image has more
headroom. It does not require adopting the wider redesign (§7.4).

**Do not treat this proposal as timing-only work.** §1 framed it as a uniformity
question and §4 as a simplification; §7 shows it also moves a hardware-safety
boundary on the relay variant. Any decision to proceed should be taken on all
three. The relay variant should decide whether the common architecture is safe;
if it cannot meet the bound on one constrained target, safety should win over
cross-target uniformity.

The PIC12F675 assessment (`docs/pic12f675_feasibility.md` §4.3) now makes the same
distinction: its ISR spike fits flash/RAM, while ISR return-stack feasibility
awaits an independent measurement on that different shell.

---

## 10. Reproducing the figures

Every number above came from the pinned XC8 in the toolchain table, invoked as
the Makefile invokes it:

```
xc8-cc -mcpu=10F322 -mdfp=<DFP> -std=c99 -O2 \
       -DBYPASS_MCU_PIC10F322 -D_XTAL_FREQ=2000000UL -D<VARIANT_MACRO> \
       <shell>.c bypass_pure.c <driver>.c -o <out>.hex
```

- **§2.1 ablation** — a copy of each shell with the guard rewritten as
  `if (CHK_PS || CHK_DC || CHK_ES || CHK_HS || CHK_PU || CHK_DRV || CHK_SFR)`,
  each macro expanding either to its original expression or to `0` under
  `-DABL_<name>`. Verified to reproduce the complete shipping polled figures
  exactly (445 / 471 / 473) and the linkable ISR figures (483 / 509 for simple /
  mute) with no `-DABL_*` defined, before any ablation was trusted. The relay ISR
  baseline fails to link as §2.2 documents.
- **§2.2 / §2.3 ISR shell** — the shipping `bypass_mcu_pic10f322.c` with five
  edits: enable `TMR2IE`/`PEIE`/`GIE` in `hw_tick_timer_start()`; add a
  `__interrupt()` handler that clears `TMR2IF`, sets a handshake flag and calls
  `debounce_integrate()`; make `ctx_` and the flag `volatile`; replace the
  `hw_wait_for_tick()` call with the AVR's `if (1U != timer_isr_called_)
  { continue; }` handshake; and snapshot `ctx_` before `debounce_step()`.
- **§2.3 stack depths** — `test/check_stack_depth_pic.sh <asm> 8 2 <label>`
  against the generated `.s`, using the fixed gate from §8.
- **Hardware stack capacity of the measured/related PIC parts** — `STACKDEPTH=8`
  in `<DFP>/xc8/pic/dat/ini/{10f320,10f322,12f675}.ini`, corroborated by
  `hwstackdepth="8"` in the corresponding `edc/PIC*.PIC` files.

The §6 figures use the PIC10F320's own single-source command line:

```
xc8-cc -mcpu=10F320 -mdfp=<DFP> -std=c99 -O2 \
       -D_XTAL_FREQ=2000000UL -D<VARIANT_MACRO> \
       bypass_mcu_pic10f320.c -o <out>.hex
```

- **Baseline** — the unmodified shipping source, confirmed to reproduce
  `make pic10f320` exactly (220 / 241 / 244 words) before any delta was trusted.
- **§6.2 non-blocking transforms** — the shipping shell with, per variant: the
  `__delay_ms()` wrapper (`hw_x4053_mute_delay` / `hw_tq2_pulse_delay`) deleted;
  `hw_set_{bypass,engaged}_state()` split at the former delay point into
  `_pre` / `_post`; an `ACTUATION_TICKS` macro per `#if defined(OUTPUT_*)` block
  (0 / 5 / 12); a `static uint8_t actuation_ticks_`; a countdown at the top of the
  loop body calling the `_post` half selected by `ctx_.effect_state` on reaching
  zero; `init()` starting the power-on bypass actuation and letting the loop
  finish it; and both toggle sites calling `_pre` and loading the counter. The
  state, the countdown and the `_post` calls are all inside
  `#if (ACTUATION_TICKS > 0U)`. The two-function comparison row is the same
  transform with `hw_actuation_begin/end(effect_state_t)` and no `#if`.
- **§6.4 range-check cost** — the same builds with
  `(actuation_ticks_ > ACTUATION_TICKS)` added to the main-loop sanity gate. Since
  the relay build does not link, its +4 words was measured indirectly: the
  `(TMR2_T2CON_CONFIG == T2CON)` term was ablated from
  `hw_critical_sfrs_intact()` to free 4 words on every variant, and both relay
  builds re-linked (248 → 252).
- **§6.5 stack depths** — `test/check_stack_depth_pic.sh <asm> 8 2 <label>` on the
  generated `.s`, and `test/pic10f320/return_stack_oracle.py --limit 8 <hex>` on
  the emitted image; both oracles run against both baseline and spike.
- **§7.3 mitigations** — five further builds on top of the §6.2 four-function
  source. *Withheld pet*: the trailing `CLRWDT()` wrapped in
  `#if (ACTUATION_TICKS > 0U) if (0U == actuation_ticks_) #endif { ... }`.
  *Idle re-drive*: a per-variant `ACTUATION_IDLE()` macro beside each
  `ACTUATION_TICKS`, invoked from an `else` on the countdown — built both as a
  macro and as a `hw_actuation_idle()` function, which is where the +3-words-for-
  an-empty-body figure comes from. *Both*, as two separate tests and again merged
  into a single `actuation_ticks_ == 0` test at the end of the loop body.
- **§6.2's delay-loop claim** — the shipping source with `CD4053_MUTE_DELAY_MS`
  changed from `5U` to `12U` and nothing else, confirming the same 241-word flash
  footprint and therefore that XC8's generated delay does not grow with the
  constant. The image bytes differ because the duration differs.

---

## 11. Cross-document follow-ups

The two PIC12F675 corrections identified by the original review have now been
applied in the owning document: ISR flash fit is no longer presented as
return-stack affordability, and the PIC10F322 linker failure is described as
fragmentation at 511/512 rather than simply "two words" oversized. The remaining
follow-ups below are recorded, **not applied**, because each belongs to its owning
document.

| Document | Claim | Correction |
|---|---|---|
| `phase2_pic_shell.md` §1 | Model B is justified by three reasons. | There is a fourth, now measured: on the relay variant the ISR alternative does not fit the part — and would exhaust the return-stack reserve even if it did. |
| `phase2_pic_shell.md` §5 | The tick-stealing divergence from the AVR is accepted behaviour. | Still accurate. Worth a forward reference to this document, which proposes removing the divergence rather than accepting it. |
| `phase2_pic_shell.md` §4/§5 | Startup actuation completes before the tick starts; a blocking pulse cannot depend on tick progress. | If non-blocking actuation is adopted, document the new serialized boot phase and the fact that timer progress becomes part of relay completion (§5.3, §7.10). |
| `pic10f320_special_case.md` §4 | The output-latch match does not fit and is deliberately omitted. | Still accurate, and this document depends on it (§6.3). Non-blocking actuation would require direction-specific transient semantics in addition to the stable-state check; that formulation is unpriced and cannot fit within the measured current headroom unless space is recovered. |
| `pic10f320_special_case.md` §5 | The shared surface is "small, finite and auditable", and the table is all of it. | Accurate today. If this proposal is adopted the table gains an actuation-timing row, and §6.7 records that `pic10f320-test-equiv` would not cover the new state — so the row would be genuinely manual, not merely documented. |
| `pic10f320_special_case.md` §4 | An `LATA` upset "persists ... until the next footswitch press re-drives the outputs". | Accurate, and §7.4 draws out what it means on the relay variant specifically: an upset that sets a coil bit strands that coil energized with no bound at all. That is a potential hardware-damage path rather than only a wrong-output path, and it exists in shipping firmware today. The idle re-drive cost +2 words atop the non-blocking spike; the same fix can be evaluated independently on the roomier current blocking image. |
| `test/README.md` PIC lock-step/fault layers | Loop `CLRWDT` is the once-per-iteration boundary and deterministic injection seam. | Withholding the pet intentionally removes that instruction during active ticks. Both PIC layers need a watchdog-independent serviced-tick boundary and phase-aware output comparison/injection (§6.7, §7.13). |
| `DESIGN_DOCUMENTATION.adoc` output timing | A 5/12 ms blocking delay defines the mute/relay interval. | Tick-counted output timing needs accepted-tick semantics, loop-position/WCET bounds, oscillator tolerance and explicit minimum/maximum physical widths (§5.5). |

Corrections inside **this** document have been applied rather than merely
recorded. The first two are cases where a later measurement overturned an earlier
recommendation, and the original claim remains visible next to its limit rather
than being quietly rewritten:

- **§3.2** recommended a two-function `hw_actuation_begin/end(effect_state_t)`
  interface. §6.2 measured that form as unaffordable on the PIC10F320. §3.2 now
  carries the four-function recommendation and the measurement that overturned the
  original.
- **§4** originally treated a much shorter watchdog as a free consequence of
  one-tick loops. §7.7 establishes the actual constraint: withholding pets keeps
  healthy output progress in the pet-to-pet budget, so the period must remain
  above actuation plus margin. Material tightening remains possible and must be
  sized rather than assumed. The bullet now carries that correction inline.

The 2026-08-06 architecture/FMEA review added further corrections rather than new
measurements: §5.3 invalidates the original startup-overlap assumption; §7.9–§7.13
add fault-abort, tick-cadence, valid-state, muted-liveness and observation-boundary
requirements; and §9 no longer recommends choosing one incomplete PIC10F320 relay
mitigation. None changes the compiled word counts in §2 or §6.
