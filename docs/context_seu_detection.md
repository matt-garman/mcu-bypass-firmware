# In-range debounce-context SEU detection (F2)

> **Scope.** This is the F2 decision and safety case: the hazard, the
> alternatives that were priced and refused, the measured cost of the spelling
> that shipped, and the oracles that hold the result in place. It is not a
> second copy of anything. The normative design of the mechanism is in
> "Failsafe Mechanisms" in
> [`DESIGN_DOCUMENTATION.adoc`](../DESIGN_DOCUMENTATION.adoc); the shipped
> transaction is in `src/`; per-part enablement is `BYPASS_CTX_CHECK_FLAG` in
> the `Makefile`; the reviewed ceilings are that document's Resource
> Utilization section; and what each image occupies is release evidence, bound
> to a source commit and a pinned toolchain.
>
> **Claim boundary.** The repository owner authored the firmware changes. The
> gates named below were run to completion on a fully provisioned host — target
> toolchains, simulators and the mutation suite included — and became
> *retained* release evidence when the `v0.9.10` cut recorded them in a signed
> MANIFEST bound to one commit. That cut was never published, so no published
> release binds them yet — see [release/README.md](../release/README.md). Local
> completion, retained release qualification and publication are separate
> claims. None of them is hardware qualification — see
> [HARDWARE_VALIDATION_LOG.md](../HARDWARE_VALIDATION_LOG.md).

## The hazard

Every shell's per-tick sanity gate rejects only **out-of-range** context
(`program_state > RELEASE_DEBOUNCE_WAIT`, `effect_state > ENGAGED`,
`debounce_counter > RELEASE_THRESH`). An **in-range** single-bit SEU/EMI upset
slips through. The dangerous case is `debounce_counter`: with
`RELEASE_THRESH = 25`, `PRESSED_THRESH = 8`, an idle counter of `0` whose bit 3
or bit 4 flips becomes `8` or `16` — both `<= 25` (passes the range gate) and
`>= PRESSED_THRESH` — so `debounce_step()` toggles the effect on the next tick.
That is a **phantom bypass/engage switch with no footswitch press**, invisible to
every existing guard.

F2's answer — a complemented XOR-fold shadow of the debounce context, and a
transactional snapshot/validate/compute/publish sequence in every enabled shell
— is specified in "Failsafe Mechanisms", along with the guarantee it makes and
the coverage it explicitly does not claim. Everything below is *why* it takes
that shape.

## Decisions (2026-08-17)

| Question | Decision | Rationale |
| --- | --- | --- |
| Representation | Complemented XOR-fold: one byte `= ~(program_state ^ effect_state ^ debounce_counter)` | Detects every single-bit flip in any member or the shadow — identical detection to per-member complement under the single-event threat model — at one byte and one check instead of three. The complement makes the all-zeros stuck-at case non-trivial. |
| Location of the math | Pure function `debounce_ctx_check_word()` in `bypass_pure.c` | Host- and CBMC-testable single source of truth. The static single-bit property is therefore host-compiled and formally checkable; storage, transaction boundaries, watchdog recovery and AVR ISR/main atomicity stay in the hardware shells. |
| Storage / transaction / recovery | Shell | The pure core is stateless. Each shell owns the persisted pair, snapshots it, validates the snapshot, computes locally, and publishes the successor. |
| Recovery action | Reset on mismatch; safe overwrite after a valid snapshot | A mismatch has no known-good persisted member. A later upset that was not consumed may instead be overwritten by the already validated transaction. |
| Member scope | All three members | The fold covers the whole context uniformly. |
| Enablement | Compile-time opt-in macro `BYPASS_CTX_CHECK` | Makes the per-part decision explicit and lets the mutation harness build a feature-off baseline. |
| Part scope | **PIC12F675, AVR classic, AVR-XT, PIC10F322** | Every part that links the pure core and has flash room. |
| **PIC10F320 excluded** | Capacity limit | 320 does not link `bypass_pure.c` at all (self-contained inlined logic), and when this was priced even the cheapest fold overflowed its 256-word flash on the relay variant. Its range-only gate stays; the exclusion is documented and tested. See "The PIC10F320 exclusion". |

## Priced alternatives

**Pass the context by value, not by pointer.** On the PIC the FSR pointer
dereference is costlier than a 3-byte struct copy — the by-pointer form
overflowed PIC10F322 in measurement. `static inline` gives no benefit either:
XC8 at `-O2` does not inline the function.

**Compile the pure function unconditionally, gate only its callers.**
`bypass_pure.c` defines `debounce_ctx_check_word()` on every build, so the host
suite exercises it even for a part that does not enable the feature; the shells
reference it only under `BYPASS_CTX_CHECK`. The alternative -- compiling the
function itself behind the macro -- would have left the fold's own arithmetic
untested wherever the feature is off.

**Flash margin note (PIC10F322).** The pre-transaction F2 image used 507/512
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
masked relay-coil clear reduced only the relay image.

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

## Why the two shell families transact differently

The transaction sequence itself is in "Failsafe Mechanisms" and in `src/`. What
is a decision, and not derivable from either, is why the two families place its
boundaries where they do.

**PIC polled shells (`pic10f322`, `pic12f675`).** One owner, no ISR, so the
whole tick is a single transaction and no interrupt discipline is needed.
`ctx_` and `ctx_check_` are volatile so the snapshot and the publication are
real persisted accesses rather than something the optimizer may elide. If
persisted SRAM changes after a byte has already been copied, the local snapshot
remains the computation source and publication overwrites the upset. If the
changed value enters the snapshot, or survives after publication, the
context/check pair mismatches and recovery follows. The publication order
briefly leaves two different generations in SRAM, but no check or consumer runs
between those stores in these single-owner loops.

**AVR ISR shells (`avr_classic`, `avr_xt`).** Integration stays in the timer ISR
so a blocking relay pulse cannot starve sampling. That gives the context two
owners, so both must run a complete transaction:

- The ISR validates its own snapshot, integrates only the local counter, and
  publishes only the counter. A mismatch skips both, leaving the mismatched pair
  for `main()` to observe and escalate.
- `main()` runs snapshot, validation, `debounce_step()`, apply and publication
  inside `ATOMIC_BLOCK(ATOMIC_RESTORESTATE)`, which is what makes it one
  transaction with respect to the ISR. That the block now encloses the whole
  transaction rather than only apply-and-re-derive is the change F2 made; see
  [`MISRA_COMPLIANCE.md`](../MISRA_COMPLIANCE.md) for the deviations the
  avr-libc macro costs.
- The watchdog is petted only after a valid main transaction, and output
  actuation uses `res`, derived from that validated local snapshot.

This design needs only `ctx_check_`; the former `ctx_fault_` handshake is gone,
so persistent F2 storage is one check byte rather than two.

## The PIC10F320 exclusion

"Failsafe Mechanisms" records the exclusion and why it is safe. What belongs
here is the margin it was decided against, and the fact that the margin has
moved.

When the fold was priced, the 320's relay variant sat at 245/256 words (11
free), and even the one-byte XOR-fold overflowed the device (linker: `can't find
words for psect ... CODE`). The relay figure has moved twice since: at `v0.9.10`
it measured 242/256 (14 free), after three words went to the coil-latch
integrity term and six came back from making the coil clear a single masked
`LATA` write.

The exclusion is **not** re-opened on that basis here. Doing so would need the
fold re-priced against the current image on all three variants, and
`cd4053_with_mute` was untouched by any of it. But the margin this decision was
made against no longer holds, so re-price rather than cite the paragraph above
if the question is raised again.

Mixing the feature onto only the 320's lighter `cd4053_simple` variant was
considered and rejected: per-variant-within-a-part inconsistency is worse than a
clean part-level line.

## Resource qualification

This change had to fit inside budgets it did not set. Those budgets, the parts
they bound and the goal that enforces each are in `DESIGN_DOCUMENTATION.adoc`'s
Resource Utilization section, which owns them; what each image occupies today is
release evidence and is not restated anywhere.

PIC10F322 is the binding constraint. It stays inside 512 words in every variant
only because the integrity-check fold pays for the transaction -- see the flash
margin note above, including the one-word-per-term cost of respelling that fold.
PIC10F320 carries no F2 at all; its own margin is the reason.

RAM and stack: the AVR `next_ctx` snapshot is an automatic, so it lands on the
stack. The stack high-water gate in the simulator suite (`make test` and
`make test-long`) measures peak stack use across every classic-AVR variant and
part, and fails unless at least 8 free bytes separate the deepest stack pointer
from the top of the static data. The ATtiny13a, with 64 B of SRAM, is the
tightest of them. On PIC10F322 this design leaves the return-stack depth
unchanged, and every variant holds a 2-level reserve inside the part's 8
hardware levels. The image, RAM, stack and static-analysis gates all passed with
the automatic `next_ctx`/`res` objects in place.

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

Which lane runs on which substrate, and what each may claim there, is
[`test/README.md`](../test/README.md)'s subject. Pass/fail counts for any one
run are release evidence, not a fact this file maintains.

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
   qualification passed on the provisioned host, with PIC10F322 the binding
   capacity case.

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
