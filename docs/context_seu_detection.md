# In-range debounce-context SEU detection (F2)

> **Design and evidence record.** The repository owner authored the firmware
> changes. The evidence below is a complete local run on a fully provisioned
> host — target toolchains, simulators and the mutation suite included — and is
> reported as observed. *Retained release* evidence for these gates now exists:
> `release/v0.9.10/` carries a MANIFEST and signed image set bound to one commit,
> inside the signed `v0.9.10` tag. That cut was never published, so no published
> release binds them yet — see [release/README.md](../release/README.md). Local
> completion, retained release qualification and publication are separate claims.
> None of them is hardware qualification — see
> [HARDWARE_VALIDATION_LOG.md](../HARDWARE_VALIDATION_LOG.md).

## Summary

Every shell's per-tick sanity gate rejects only **out-of-range** context
(`program_state > RELEASE_DEBOUNCE_WAIT`, `effect_state > ENGAGED`,
`debounce_counter > RELEASE_THRESH`). An **in-range** single-bit SEU/EMI upset
slips through. The dangerous case is `debounce_counter`: with
`RELEASE_THRESH = 25`, `PRESSED_THRESH = 8`, an idle counter of `0` whose bit 3
or bit 4 flips becomes `8` or `16` — both `<= 25` (passes the range gate) and
`>= PRESSED_THRESH` — so `debounce_step()` toggles the effect on the next tick.
That is a **phantom bypass/engage switch with no footswitch press**, invisible to
every existing guard.

F2 adds a **complemented XOR-fold** shadow of the debounce context and makes
every enabled shell's use of persisted state transactional. A tick snapshots
`ctx_`, validates that snapshot against `ctx_check_`, computes only from the
validated local value, then publishes the successor context and its check word.
A single-bit upset confined to persisted `ctx_` or `ctx_check_` therefore either
fails validation and forces watchdog recovery, is safely overwritten by a
successor derived from the earlier valid snapshot, or remains as a mismatch for
the next validation. It is never consumed and then legitimized by re-folding
the corrupted persisted value.

The guarantee is intentionally bounded. It assumes program code, control flow,
registers, and automatic local objects execute correctly; it does not claim to
cover a fault in `next_ctx`, `res`, the stack, a CPU register, or an output
peripheral. The fold arithmetic lives in the **pure core** (`bypass_pure.c`), so
its static single-bit property is host-compiled and CBMC/unit-testable. Storage,
transaction boundaries, watchdog recovery, and AVR ISR/main atomicity remain in
the hardware shells.

## Decisions (2026-08-17)

| Question | Decision | Rationale |
| --- | --- | --- |
| Representation | Complemented XOR-fold: one byte `= ~(program_state ^ effect_state ^ debounce_counter)` | Detects every single-bit flip in any member or the shadow — identical detection to per-member complement under the single-event threat model — at one byte and one check instead of three. The complement makes the all-zeros stuck-at case non-trivial. |
| Location of the math | Pure function `debounce_ctx_check_word()` in `bypass_pure.c` | Host- and CBMC-testable single source of truth. |
| Storage / transaction / recovery | Shell | The pure core is stateless. Each shell owns the persisted pair, snapshots it, validates the snapshot, computes locally, and publishes the successor. |
| Recovery action | Reset on mismatch; safe overwrite after a valid snapshot | A mismatch has no known-good persisted member. A later upset that was not consumed may instead be overwritten by the already validated transaction. |
| Member scope | All three members | The fold covers the whole context uniformly. |
| Enablement | Compile-time opt-in macro `BYPASS_CTX_CHECK` | Makes the per-part decision explicit and lets the mutation harness build a feature-off baseline. |
| Part scope | **PIC12F675, AVR classic, AVR-XT, PIC10F322** | Every part that links the pure core and has flash room. |
| **PIC10F320 excluded** | Capacity limit | 320 does not link `bypass_pure.c` at all (self-contained inlined logic), and when this was priced even the cheapest fold overflowed its 256-word flash on the relay variant. Its range-only gate stays; the exclusion is documented and tested. The relay image has since shrunk, so the margin that decision rested on has moved -- see "PIC10F320 -- excluded, and why that is safe". |

## The pure-core addition

`bypass_pure.h` — declare (place after `debounce_step`'s declaration):

```c
// F2: complemented XOR-fold over the persisted debounce context, for
// in-range single-event-upset detection.  The shell stores the returned word
// alongside its context, re-derives it after every legitimate mutation, and
// forces recovery when a later tick's re-derivation no longer matches the
// stored word.  Pure and host/CBMC-testable.
uint8_t debounce_ctx_check_word(debounce_context_t const ctx);
```

`bypass_pure.c` — define:

```c
uint8_t debounce_ctx_check_word(debounce_context_t const ctx) {
    return (uint8_t)~(uint8_t)(
            (uint8_t)ctx.program_state
          ^ (uint8_t)ctx.effect_state
          ^ ctx.debounce_counter);
}
```

By **value**, not by pointer: on the PIC the FSR pointer dereference is costlier
than a 3-byte struct copy — the by-pointer form overflowed PIC10F322 in
measurement. `static inline` gives no benefit (XC8 at `-O2` does not inline it).
The function is always compiled into `bypass_pure.c` (so the host suite always
exercises it) and is referenced by the shells only under `BYPASS_CTX_CHECK`.

## Shell wiring — PIC polled shells (`pic10f322`, `pic12f675`)

These shells have one owner and no ISR. `ctx_` and `ctx_check_` are volatile so
the transaction performs an actual persisted snapshot and publication. Each
tick follows this sequence:

1. Copy `ctx_` to `next_ctx` exactly once.
2. Compare `ctx_check_` with `debounce_ctx_check_word(next_ctx)` and apply every
   range/output/SFR guard to `next_ctx`.
3. Integrate and call `debounce_step()` using only `next_ctx`.
4. Apply the returned state and lockout to `next_ctx`.
5. Derive the check from `next_ctx`, then publish `next_ctx` to `ctx_`.
6. Act on `res` only after that transaction has completed.

The essential shape is:

```c
debounce_context_t next_ctx = ctx_;
if ((ctx_check_ != debounce_ctx_check_word(next_ctx)) ||
        /* range and hardware guards using next_ctx */) {
    hw_force_wdt_reset();
}

next_ctx.debounce_counter = debounce_integrate(
        hw_read_footswitch(), next_ctx.debounce_counter);
debounce_step_result_t res = debounce_step(next_ctx);
/* apply res to next_ctx */
ctx_check_ = debounce_ctx_check_word(next_ctx);
ctx_ = next_ctx;
/* act on res */
```

If persisted SRAM changes after a byte has already been copied, the local
snapshot remains the computation source and publication overwrites the upset.
If the changed value enters the snapshot, or survives after publication, the
context/check pair mismatches and recovery follows. The publication order
briefly leaves two different generations in SRAM, but no check or consumer runs
between those stores in these single-owner loops.

**Flash margin note (PIC10F322):** the pre-transaction F2 image used 507/512
words in the relay variant, so the transaction did not fit as first written. The
snapshot and publication struct copies cost 18 words -- 12 in `main()`, 6 in
`init()` -- taking the simple/mute/relay variants to 496/522/525 of 512 and
overflowing the two larger images. The transaction itself stayed intact. Folding
the three pure-read integrity checks in `bypass_mcu_pic10f322.c`
(`hw_critical_sfrs_intact()`, `hw_footswitch_pullup_intact()` and
`hw_output_state_intact()`) from `&&` chains into branchless XOR-then-OR
accumulators recovered 20 words: XC8's free-mode codegen spends roughly 5
program words of branch scaffolding on every short-circuit term, and every term
in those three functions is a pure SFR read, so the fold is exactly equivalent,
and constant-time as a bonus. The same trick applied to `main()`'s sanity `||`
chain costs 32 words rather than saving them -- its terms are calls and
comparisons that need an explicit `? 1U : 0U` -- so that chain is deliberately
left short-circuit. At F2 landing the folded image measured 476/502/505 words,
two words better in the relay variant than the pre-transaction image. The later
masked relay-coil clear reduced only the relay image, leaving the current matrix
at 476/502/493; see Resource qualification below.

That margin is thin enough that the *spelling* of the fold matters, not just its
logic, and the accumulator must stay `diff |= term`. Respelling it as the
explicit `diff = (uint8_t)(diff | term)` costs one program word per term under
XC8 free mode -- 10 words across the three functions. At F2 landing that
exhausted the mute image's 512 words and put relay over capacity; the current
relay image has since become smaller for an unrelated reason. Hoisting each term
into a named local ahead of a single closing fold costs 12. Both were measured,
not estimated.

That respelling was tried once, to silence a `-Wconversion` diagnostic which
GCC 8.5.0 raises on the compound-assignment form. Supporting a host compiler
that old is not a project goal: GCC 13.3.0 accepts `diff |= (uint8_t)term`
without complaint, because the result of OR-ing two `uint8_t` values provably
fits the destination. The fold therefore keeps the compact spelling and the
rewrite was reverted. Any future rewrite of these three functions must be
re-measured against the 512-word gate rather than assumed free.

## Shell wiring — AVR ISR shells (`avr_classic`, `avr_xt`)

The AVR shells keep integration in the timer ISR so a blocking relay pulse does
not starve sampling. Both the ISR and `main()` therefore own a complete
transaction:

- The ISR snapshots `ctx_`, validates that snapshot, integrates only the local
  counter, derives the check from the local successor, and publishes only the
  counter. A mismatch skips integration and publication. `main()` then observes
  the unchanged mismatched pair and enters watchdog recovery.
- `main()` enters `ATOMIC_BLOCK(ATOMIC_RESTORESTATE)` before taking its snapshot.
  The block validates, runs `debounce_step()`, applies the result locally,
  derives the check from the local successor, and publishes the whole context.
  Disabling interrupts makes this one transaction with respect to the ISR.
- The watchdog is petted only after a valid main transaction. Output actuation
  uses `res`, which was derived from that validated local snapshot.

The essential ISR shape is:

```c
debounce_context_t next_ctx = ctx_;
if (ctx_check_ == debounce_ctx_check_word(next_ctx)) {
    next_ctx.debounce_counter = debounce_integrate(
            hw_read_footswitch(), next_ctx.debounce_counter);
    ctx_check_ = debounce_ctx_check_word(next_ctx);
    ctx_.debounce_counter = next_ctx.debounce_counter;
}
```

The essential main-loop shape is:

```c
debounce_step_result_t res;
ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
    debounce_context_t next_ctx = ctx_;
    timer_isr_called_ = TIMER_ISR_NOT_CALLED;
    if (ctx_check_ != debounce_ctx_check_word(next_ctx)) {
        hw_force_wdt_reset();
    }
    res = debounce_step(next_ctx);
    /* apply res to next_ctx */
    ctx_check_ = debounce_ctx_check_word(next_ctx);
    ctx_ = next_ctx;
}
hw_wdt_pet();
/* act on res */
```

This design needs only `ctx_check_`; the former `ctx_fault_` handshake is gone.
The atomic block is still required, but now encloses snapshot, validation,
computation, and publication rather than only apply-and-re-derive.

## PIC10F320 — excluded, and why that is safe

PIC10F320 is the self-contained special-case shell: it does not link
`bypass_pure.c`, inlining its own `debounce_integrate`/`debounce_step` to fit
256 words. When this was priced its relay variant sat at 245/256 (11 free), and
even the one-byte XOR-fold overflowed the device (linker: `can't find words for
psect ... CODE`). So 320 keeps its existing range-only gate and does **not**
define `BYPASS_CTX_CHECK`.

> The relay figure has moved twice since, and the current one is 242/256
> (14 free): `v0.9.10` added three words for the coil-latch integrity term and
> then returned six by making the coil clear a single masked `LATA` write. The
> exclusion is **not** re-opened on that basis here -- doing so would need the
> fold re-priced against the current image on all three variants, and
> `cd4053_with_mute` at 241/256 is untouched by any of it -- but the margin this
> decision was made against no longer holds, so re-price rather than cite the
> paragraph above if the question is raised again. This is recorded as a per-target capacity difference (per the
review's "document and test per-target differences rather than silently weaken
one target"), and a focused test asserts the 320 images never reference the F2
symbol. Mixing the feature onto only 320's lighter `cd4053_simple` variant
(36 free) was considered and rejected: per-variant-within-a-part inconsistency is
worse than a clean part-level line.

## Enablement

`-DBYPASS_CTX_CHECK` is present in the CFLAGS of the four enabled parts:
`PIC10F322_CFLAGS`, `PIC12F675_CFLAGS`, and the AVR classic + AVR-XT flag sets.
Do **not** add it to `PIC10F320_CFLAGS`. `bypass_pure.c` always compiles the pure
function regardless (the host suite links it unconditionally).

## Resource qualification

These are the latest fully provisioned candidate measurements for the build that
carries the transaction and OR-folded integrity checks: XC8 v3.10 (free mode,
`-O2`) for the PIC parts, avr-gcc for the AVR parts. They remain working values
until the production release's strict resource gate remeasures all 21 images and
retains its source-commit-bound result. The PIC10F322 row is the one F2 had to
fit inside, but every row here has moved since F2 landed, for later firmware
work outside this design; read them as current occupancy rather than as this
change's cost.

| Part | Budget | Simple / mute / relay | Tightest margin |
| --- | --- | --- | --- |
| PIC10F322 | 512 words | 476 / 502 / 493 words | 10 words (mute) |
| PIC12F675 | 1024 words | 548 / 574 / 585 words | 439 words (relay) |
| ATtiny13a (AVR classic) | 921 B | 838 / 878 / 868 B | 43 B (mute) |
| ATtiny202 (AVR-XT) | 2048 B | 968 / 1008 / 1040 B | 1008 B (relay) |
| PIC10F320 | 256 words | 220 / 241 / 242 words | 14 words; F2 excluded |

PIC10F322 is the binding constraint, and it stays inside 512 words in every
variant only because the integrity-check fold pays for the transaction -- see
the flash margin note above, including the one-word-per-term cost of respelling
that fold. The ATtiny13a budget is the gate's 90%-of-1024 utilisation limit, not
the raw device size. PIC10F320 carries no F2 at all; its row records that the
part still builds and where its own margin sits.

RAM and stack: the AVR `next_ctx` snapshot is an automatic, so it lands on the
stack. The stack high-water gate in the simulator suite (`make test` and
`make test-long`) measures 31-33 B of stack use across every classic-AVR variant and
part. With 5 B of static data, aggregate occupancy is 36-38 B. The tightest
margin is the ATtiny13a, whose 64 B of SRAM leaves 26 B free, against the gate's
8 B floor. PIC10F322 return-stack depth is unchanged at 3 levels
(`cd4053_simple`, `cd4053_with_mute`) and 4 (`tq2_l2_5v_relay`), each carrying a
2-level reserve inside the part's 8 hardware levels. The image, RAM, stack and
static-analysis gates all passed with the automatic `next_ctx`/`res` objects in
place.

The transaction also removes the former AVR `ctx_fault_`, so persistent F2
storage is one check byte rather than two bytes.

## Test and mutation evidence

- **Pure host/CBMC:** existing unit and formal checks prove the fold changes for
  each single-bit context-member upset and equals the specified complemented
  XOR expression. This is a static pair-at-validation property, not the temporal
  transaction proof.
- **PIC shipping-source host harness:** a one-shot bit-4 counter upset is injected
  from inside the successful check call, after the healthy by-value argument was
  captured. Both PIC shells must overwrite it without an output change or a
  live-global re-fold.
- **Classic AVR simavr:** one-shot cases stop at the ISR check call and at
  `debounce_step()` in main, covering both transaction owners.
- **AVR-XT yasimavr:** equivalent ISR and main one-shot mechanisms are pinned in
  the 24-injection fault matrix, plus the healthy negative control.
- **Mutation:** transaction-seam mutants make AVR integration consume live
  `ctx_` and make each PIC publication re-fold live `ctx_`; the one-shot probes
  must kill them. Existing fold and missing-check mutants remain.
- **PIC10F320 exclusion:** the mutation runner asserts that its shell does not
  reference `debounce_ctx_check_word` and that `BYPASS_CTX_CHECK` is undefined
  there.

The initial host PIC coverage and ATtiny fault-oracle checks passed. A subsequent
fully provisioned run passed the AVR/XC8 builds and resource gates,
simavr/yasimavr/gpsim lanes, CBMC and static analysis, and the complete mutation
suite: 132 killed, 0 survived, 0 errored, and no skipped PIC or ATtiny202 rows.
Both were local runs on the maintainer's provisioned host. The same gates became
*retained* release evidence when the `v0.9.10` cut recorded them in a signed
MANIFEST bound to one commit. That release was never published; see
[release/README.md](../release/README.md).

## Acceptance-criteria mapping (F2)

1. A single-bit upset confined to persisted `ctx_`/`ctx_check_` is detected or
   safely overwritten; no transaction consumes and re-folds the upset.
2. Output actuation is based only on `res` from a validated local snapshot.
3. AVR ISR and main transactions cannot interleave because main's complete
   transaction is inside `ATOMIC_BLOCK`; clean dynamic simulation confirms that
   this introduces no false reset.
4. One-shot post-check probes and transaction-seam mutants provide the temporal
   evidence; repeated favorable-phase injection is not accepted as proof.
5. Flash, RAM, stack, MISRA, mutation, simulator, and shipping-source
   qualification passed on the provisioned host. PIC10F322 remains the binding
   capacity case at 502/512 words for the mute variant.

## Related

- `CHANGELOG.md` / Git history — the durable record of this work. The
  `TODO.md` `T3-ctx-complement` task that tracked it was removed on completion,
  per that file's "completed work is removed" convention.
- The F2 / F3 review items, recorded in `CHANGELOG.md` and Git history — F3
  carries the "cover `debounce_counter` and equivalently exposed members, not
  the fail-safe single-byte guards" constraint, satisfied here by folding
  exactly the three context members.
- `docs/relay_coil_fault_correction.md` — F1, the sibling fault-hardening item.
  It now shares this one's detect-and-reset shape: an energized relay coil is
  escalated to a fail-safe recovery rather than corrected in place.
