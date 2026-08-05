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
   words, and no checks surrendered — and it delivers uniform timing on *every*
   platform including the AVR, not just parity between two of them (§3).
4. The API shape this needs is **already the shape of the drivers**. Both
   blocking drivers are exactly `pre-action; one delay; post-action` — verified
   against the source, not assumed (§3.1). It must be **four functions, not two**:
   a target-state parameter is a literal at every call site and free-tier XC8
   still charges for it. Measured (§3.2, §6.2).
5. It is **not free**, and on the PIC10F322 the largest cost lands on the very
   checks §2 was trying to protect: a deliberate transient window appears in
   which the output latches match neither BYPASS nor ENGAGED, and
   `hw_is_sanity_check_failed()` must learn about it (§5.1). That cost is
   **unmeasured** there and is the first thing a spike should price.
6. **The PIC10F320 — the most constrained part — fits it, and is the cheapest
   part to convert.** Measured end to end (§6): +0 / +8 / +8 words, the return
   stack unchanged, and §5's transient-state cost is *zero* because this part
   already omits the output-latch check that the cost falls on. What does not fit
   is range-checking the new state variable: that costs 4 words and puts the
   relay variant exactly on 256, unlinkable (§6.4).

**Date / branch:** 2026-08-05. §2–§5 measured on `main` @ `59d55e9`; §6 measured
on `main` @ `831d1d3`.

**Toolchain used for every figure below** — the versions pinned in
`TOOLCHAIN.adoc`, with no additions:

| Tool | Version | Where |
|---|---|---|
| XC8 (free tier) | v3.10 | `/opt/microchip/xc8/v3.10/bin/xc8-cc` |
| Device pack | PIC10-12Fxxx DFP v1.9.189 | `/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8` |

> Scope note: every figure here comes from **throwaway spikes** written outside
> the repository — an ISR-converted copy of the shipping
> `src/bypass_mcu_pic10f322.c`, a macro-ablatable copy of each shell used to price
> the checks one at a time, and (for §6) three non-blocking transforms of
> `src/bypass_mcu_pic10f320.c`. None is proposed code and none is checked in. §9
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
words and 8 of 8 stack levels on the variant that most needs it, and the currency
available to pay with buys only one of those two. There is also an irony worth
recording — `cd4053_simple` is the one variant with comfortable room (483 words,
1 stack level spare) and it is the one variant that never blocks, so it gains
nothing from an ISR at all. **The variants that need the concurrency are exactly
the ones that cannot afford it.**

---

## 3. The alternative: remove the blocking delay instead

The ISR model lets a second execution context keep running *through* a blocking
delay. The other way to reach the same place is to stop blocking.

Drive the coil pulse and the mute gap as a tick-counted state in the existing
polled loop. The loop already runs once per millisecond on every platform; an
actuation that takes 12 ms becomes a countdown of 12 iterations rather than 12 ms
spent inside `__delay_ms()`.

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

One byte of state and a countdown in the existing loop:

```c
static uint8_t actuation_ticks_;   /* 0 == idle */
```

On a toggle, call the `_pre` half for the new state and load the counter. On each
subsequent tick, decrement; on reaching zero, call the `_post` half selected by
`ctx_.effect_state`. Wrapping that block in `#if (BYPASS_ACTUATION_TICKS > 0U)`
compiles it away entirely where the count is zero, so `cd4053_simple` degenerates
to today's code — measured byte-for-byte identical, not asserted (§6.2).

Note this replaces a *blocking* dependency with a *state* dependency, which is
the trade being proposed: the loop gets slightly more complex so that its timing
gets simpler.

---

## 4. The simplification case

The reason to take this seriously is not the relay variant. It is that a pile of
existing complexity exists only to accommodate blocking, and would be deleted:

- **`src/bypass_blocking_delay.h` disappears entirely.** That header exists only
  to paper over avr-libc's `_delay_ms()` versus XC8's `__delay_ms()`. Deleting a
  portability shim is a real reduction in surface, not a relocation of it.
- **The tick-stealing divergence goes away.** `docs/phase2_pic_shell.md` §5
  documents it as accepted behaviour; it stops existing rather than staying
  documented.
- **The soak harness stops needing per-variant timing.** `pic_soak_block_*` in
  the Makefile (0 / 5 / 12) and the `SOAK_PRESS_HOLD_MS = PRESSED_THRESH +
  SOAK_ACTUATION_BLOCK_MS + 10` arithmetic in `test/pic/test_soak_pic.cc` exist
  purely to widen the stimulus windows by the block length. Both collapse to one
  variant-independent number.
- **Both watchdogs could tighten.** The PIC's ~256 ms (`WDTPS` 1:8192) and the
  AVR's `WDTO_250MS` are both sized for a worst-case pet-to-pet window dominated
  by the coil pulse — ~14 ms on the PIC (1 ms tick + 12 ms pulse; the PIC pets at
  the end of the loop body) and ~13 ms on the AVR (which pets before actuating).
  Non-blocking collapses that window to roughly one tick, which would permit a
  materially shorter watchdog period on both families. **That is a reliability
  improvement, not a cleanup** — it is the strongest argument in this document.

The interface gets wider (two functions where there was one call site) and the
conceptual model gets narrower (one timing story instead of two). That is usually
the right direction, and the intuition that a more complex API can be a
project-level simplification is, in this case, correct.

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

The check must therefore learn a third, transient expectation, or be suppressed
across the window. Either costs flash on a part where §2 established there is
none to spare, and "suppressed" is the option that quietly weakens exactly the
SEU/EMI detection the project treats as a first-class requirement.

**This is unmeasured on the PIC10F322.** It is the first thing a spike should
price there, because it determines whether this proposal is a clean win or merely
relocates the squeeze.

On the PIC10F320 the same cost is **zero**, for a reason that inverts the
expected ordering between the two parts — §6.3.

### 5.2 A second toggle can now land mid-actuation — and provably does not

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
the release budget" to "no toggle can land inside an actuation window". Same
constraint, stronger reason, and it should be re-commented rather than reused
silently.

### 5.3 The drivers are shared, so the AVR moves too

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

---

## 6. The PIC10F320: measured, and it fits

The obvious expectation is that the most flash-constrained part in the project is
the one that cannot have this. That expectation is wrong twice over, and both
reversals are measured below.

Everything in this section was built with the same pinned XC8 and DFP as §2,
invoked as the Makefile invokes it. The baseline reproduces
`make pic10f320` exactly (220 / 241 / 244 words), which is what makes the deltas
trustworthy.

### 6.1 Why this part asks a different question

`src/bypass_mcu_pic10f320.c` is architecturally unlike every other shell —
`docs/pic10f320_special_case.md` is the authoritative statement of why. Three of
its properties change the shape of this question:

- **It links none of `src/bypass_output_*.c`.** Its output stages are
  source-local static functions selected by `#if defined(OUTPUT_*)`. So §5.3 does
  not reach it: converting the shared drivers changes nothing here, and this part
  must be converted by hand.
- **It uses no interrupts at all.** There is no `__interrupt` handler and `GIE` is
  only ever cleared. So unlike §2, this is a pure flash question with no
  return-stack question hiding behind it (confirmed in §6.5).
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
from 5 to 12 produces an identical 241-word image, so the 12 ms coil pulse and the
5 ms mute gap cost exactly the same flash today.

### 6.3 The §5.1 transient-state cost is zero here

§5.1 identified the sanity checks learning a transient output state as the largest
and only unpriced cost of this proposal. On the PIC10F320 it does not arise.

`hw_is_sanity_check_failed()` in this shell resolves, in every variant, to
`hw_output_pins_intact()` — an exact `TRISA` comparison. It checks pin
**directions**, and directions do not change during an actuation. There is no
output-latch assertion to teach a third state to.

The reason is recorded in `docs/pic10f320_special_case.md` §4: the full
output-latch match is **deliberately omitted on this part** for flash, and is the
one defensive check the PIC10F322 carries that the PIC10F320 does not
(`hw_output_state_intact()`).

So the ordering inverts: **the most constrained part is the cheapest one to
convert, precisely because it already gave up the check that makes conversion
expensive.** That is a real finding, but it should be read carefully. It does not
mean the PIC10F320 solved a problem the PIC10F322 has — it means the PIC10F320
already paid for this, in a different currency, and the receipt is filed under a
different heading.

It has one forward-looking cost. §4 of the special-case document records the
latch check as priced-and-rejected, not as unwanted. Under non-blocking actuation
re-adding it would require a third, transient expectation, making it strictly more
expensive than the two-state version that already did not fit. **Converting this
part forecloses that option**, and that should be a deliberate decision rather
than a discovered consequence.

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
3. **Find 4 words elsewhere**, which means reopening exactly the trade §2 and §8
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
stimulus holds by the block length. Non-blocking actuation makes the tick count
explicit state that the host models exactly, which converts an accommodated
divergence into a checked one.

**It removes this part from the timing caveat.** The PIC10F320's special-case
status is *architectural* — the hand-inlined core — not temporal. Nothing about
256 words forces its debounce timing to differ from every other target. Uniform
timing across the entire matrix, PIC10F320 included, is therefore achievable,
which is a stronger version of the goal than §1 assumed was on the table.

### 6.7 What conversion costs on this part specifically

- **The new state falls outside the automated equivalence gate.**
  `pic10f320-test-equiv` steps the real firmware against the real
  `src/bypass_pure.c` and compares `ctx_`. `actuation_ticks_` is shell-local, so
  nothing compares it to anything. It joins the manually-synced surface.
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
  cycles and would need a tolerance band rather than an equality.
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

## 7. Related finding: the stack gate could not measure an ISR build

Discovered while taking the §2.3 measurements, and **fixed in the same commit as
this document**.

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
- **It failed closed, structurally.** A dropped edge always leaves an uncalled
  function that is not an XC8 entry point, and that check runs before any depth
  is reported — so the failure mode was a confusing error, never a silent
  under-count. The bad direction was not available.
- **The gate's analysis was already right.** It sums the reset and interrupt
  trees and adds the hardware-pushed return address, and `test_stack_depth_pic.sh`
  case 11 already covered ISR summing. That case passed because its synthetic
  helper is spelled `_ihelp`; only the lexer had not been told what real XC8
  emits.

The fix admits `i[0-9]+_` and is deliberately no broader — startup code calls
runtime helpers such as `clear_ram0` from outside any function psect, and the
leading-underscore requirement is what keeps those from parsing as calls. A
future unrecognized prefix still fails closed by the same mechanism. Regression
case 12 in `test/test_stack_depth_pic.sh` uses the name XC8 actually emits, and
fails against the pre-fix gate.

---

## 8. Recommendation

**Do not trade self-health checks for an ISR on the PIC10F322.** The purchase
price is a 511/512-word image with 0 of 8 stack levels spare on the relay
variant — both resources at 100% — to remove a timing difference that is not
observable. For firmware whose stated goal is textbook-grade reference quality,
that is the wrong place to spend the last of two budgets at once. Dropping the
`ctx_` range checks specifically is backwards under an ISR, since `ctx_` becomes
state shared across two execution contexts and is *more* exposed, not less.

**If uniform timing is worth pursuing, non-blocking actuation is the better
instrument.** It attacks the divergence at its source, benefits every platform
rather than reconciling two, deletes more than it adds (§4), and leaves the
self-health checks intact.

**The next step is a spike, not an implementation.** Specifically: build the
transient-state sanity check from §5.1 on the PIC10F322 relay variant and measure
it. If the actuating-state check fits inside the ~40 words that non-blocking
actuation frees by deleting `BYPASS_DELAY_MS` and its call sites, this is a clean
win on all three variants. If it does not, the proposal trades one flash squeeze
for another and should be reconsidered on the AVR first, where there is room to
prove the design before porting it back.

**Use the four-function `_pre`/`_post` interface, not a parameterised pair.**
This is settled by measurement rather than taste (§3.2, §6.2), and getting it
wrong is not a style regression — it does not link.

**The PIC10F320 should be the last target converted, not the first.** §6
establishes that it fits and, unexpectedly, that it is the cheapest part to
convert. Neither is a reason to start there. It has 4 spare words on its relay
variant, no automated gate covering the new state (§6.7), and a defensive-layer
decision to settle first (§6.4). Prove the design where being wrong is
recoverable — the AVR parts, then the PIC10F322 — and port it here once the shape
has stopped moving. Two of the findings in §6 were only visible *because* this
part has no margin; that makes it an excellent validator and a poor prototype.

**Settle §6.4 before writing code, not at link time.** Whether
`actuation_ticks_` is range-checked in the sanity gate decides whether the
PIC10F320 relay variant builds at all. It is a defensive-layer policy question
that `docs/pic10f320_special_case.md` §4 has precedent for, and it should be
answered in that document's terms rather than discovered by the linker.

Note also that the PIC12F675 assessment
(`docs/pic12f675_feasibility.md` §4.3) is unaffected as to flash but **not** as
to the stack — see §10.

---

## 9. Reproducing the figures

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
  `-DABL_<name>`. Verified to reproduce the shipping figures exactly (445 / 473
  polled, 483 ISR) with no `-DABL_*` defined, before any ablation was trusted.
- **§2.2 / §2.3 ISR shell** — the shipping `bypass_mcu_pic10f322.c` with five
  edits: enable `TMR2IE`/`PEIE`/`GIE` in `hw_tick_timer_start()`; add a
  `__interrupt()` handler that clears `TMR2IF`, sets a handshake flag and calls
  `debounce_integrate()`; make `ctx_` and the flag `volatile`; replace the
  `hw_wait_for_tick()` call with the AVR's `if (1U != timer_isr_called_)
  { continue; }` handshake; and snapshot `ctx_` before `debounce_step()`.
- **§2.3 stack depths** — `test/check_stack_depth_pic.sh <asm> 8 2 <label>`
  against the generated `.s`, using the fixed gate from §7.
- **Stack depth of both parts** — `STACKDEPTH=8` in
  `<DFP>/xc8/pic/dat/ini/{10f322,12f675}.ini`, corroborated by
  `hwstackdepth="8"` in the corresponding `edc/PIC*.PIC`.

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

---

## 10. Corrections this implies for other documents

Recorded, **not applied** — each belongs to the document that owns the claim.

| Document | Claim | Correction |
|---|---|---|
| `pic12f675_feasibility.md` §4.3 | The PIC12F675's flash headroom makes the ISR model affordable. | True **for flash only**. Both parts declare `STACKDEPTH=8`, so the 12F675's flash advantage does not extend to the return stack. The relay-variant stack cost measured in §2.3 (6 used, 0 spare) has no reason to be smaller there and must be measured before the ISR model is called affordable on that part. |
| `pic12f675_feasibility.md` §4.3 | The PIC10F322 relay ISR build "misses by two words". | Accurate as the linker's message, but the mechanism is fragmentation at 511/512 with a largest contiguous free run of 1 word (§2.2), not a program 2 words too large. |
| `phase2_pic_shell.md` §1 | Model B is justified by three reasons. | There is a fourth, now measured: on the relay variant the ISR alternative does not fit the part — and would exhaust the return-stack reserve even if it did. |
| `phase2_pic_shell.md` §5 | The tick-stealing divergence from the AVR is accepted behaviour. | Still accurate. Worth a forward reference to this document, which proposes removing the divergence rather than accepting it. |
| `pic10f320_special_case.md` §4 | The output-latch match does not fit and is deliberately omitted. | Still accurate, and this document depends on it (§6.3). Worth recording that non-blocking actuation would make re-adding it strictly more expensive — a third, transient expectation on top of the two-state version that already did not fit. |
| `pic10f320_special_case.md` §5 | The shared surface is "small, finite and auditable", and the table is all of it. | Accurate today. If this proposal is adopted the table gains an actuation-timing row, and §6.7 records that `pic10f320-test-equiv` would not cover the new state — so the row would be genuinely manual, not merely documented. |

One correction inside **this** document has already been applied rather than
recorded: §3.2 previously recommended a two-function `hw_actuation_begin/end(
effect_state_t)` interface. §6.2 measured that form as unaffordable on the
PIC10F320, and §3.2 now carries both the four-function recommendation and the
measurement that overturned the original one.
