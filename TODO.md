# Remaining work toward textbook reference quality

Status note: the firmware and test/validation suite have been meta-reviewed
several times (design doc, firmware implementation, golden-model accuracy, test
correctness, and additional verification opportunities). The firmware has no
known correctness defects; `make test` passes clean across all three output
variants and every supported MCU family. The reviews confirmed: (1) the design
meets its stated goals; (2) no bugs, race conditions, or footguns were found in
the firmware; (3) the golden model matches the firmware exactly via three
independent verification paths; and (4) all existing tests are correct and
meaningful. The items below are deferrable polish and credibility work — none
are bugs. Anything that *is* a bug gets fixed immediately, not parked here.

**Update (2026-07-10):** a subsequent external review of the multi-MCU build
did surface one real correctness defect — the TMUX4053 direct-drive (`_tmux`)
output variants drove the analog-switch control pin at the inverted MCU
polarity (BYPASS asserted at pin-high instead of the fail-safe pin-low), which
mis-switched the effect and, on the muted variant, transited the invalid
FXN+JOU-short state. Root cause: the polarity wrapper modeled the CD4053
MOSFET-inverter vs TMUX direct-drive electrical difference but not the swapped
analog throws, which cancel it. Fixed by driving one MCU polarity for both
boards and deleting the wrapper; the now-identical `_tmux` build variants were
dropped. Re-validated green. So the "no bugs found" claim above holds for the
firmware *as it now stands*, but the record should note that this one was found
and corrected here.

**Housekeeping note (2026-07-26):** this file was audited against the actual
test suite, Makefile targets, and CI. Completed work was removed rather than
kept as `— DONE` entries (git history and `CHANGELOG.md` are the record for
that), and items judged not worth doing were moved to "Considered and declined"
with their reasoning so they do not get re-proposed. Everything remaining below
was verified to still be open.

---

## Tier 2 — closes verification / traceability gaps

**Datasheet citations in the design doc.** The sleep-wakeup §7.3 cite lives in
`bypass_mcu_avr_classic.c`; the *design doc itself* currently cites no datasheet
sections at all (verified: zero datasheet references in
`DESIGN_DOCUMENTATION.adoc`). Each load-bearing decision should trace to a
page/section: WDT ~16 ms post-reset window; WDTON always-on; internal-RC ±10%;
Timer0 CTC formula; BOD level. The PIC shell's datasheet facts are already
recorded in `docs/phase2_pic_shell.md` §2 and can be cross-referenced rather
than duplicated.

---

## Tier 2.5 — additional software verification

These items were identified during a full meta-review of the firmware, design
doc, and test suite (2026-06-18) and re-verified as open on 2026-07-26. All
close residual verification gaps that can be addressed in software.

**~~A severed `-D<MACRO>=$(VAR)` compile-line contract is silent, and the fuse
checker demonstrates it.~~ DONE for the fuse bytes (2026-08-03); the sweep over
the other `-D` macros is split out below.** Raised by the `v0.9.8` meta-review:
the same silent-severance class as the four name-contract axes, on the one
interface those axes deliberately do not cover, because the C macro names are
the tests' own interface and were not renamed with the Make variables.

The defect, measured before the fix: `test/avr/test_fuses.c` declared itself the
single source of truth for fuse bytes and then defined `#ifndef` fallbacks for
all eleven, **ten of which were exactly the current values**. The real compile
line minus `-DT85_LFUSE` printed `fuse checks: 46 checks, 0 failures` and exited
0. Only `T13_LFUSE` failed, by luck, on a fallback that had gone stale.

Fixed as specified. The eleven fallbacks are `#error`s, each naming the Makefile
variable its byte comes from, and `test/test_fuse_injection_contract.py` (gate
`test-fuse-injection-contract`, in `TEST_GATES_LATE`, 14 checks in ~4 s) follows
each byte the whole way. Three things the specification did not anticipate:

- **The round trip needed a fourth link the item did not list: *burned* ==
  *injected*.** Comparing the printed byte against `make -s print-<VAR>` proves
  the checker reads the Makefile, not that it reads the byte anyone flashes. The
  gate now harvests the `-U <mem>:w:$(VAR):m` variables out of the avrdude
  recipes and requires that set to equal the `-D` set exactly. A checker
  verifying a byte no flash target burns is decoration, and it would look
  identical from the inside.
- **The value link is not redundant with the checker's own assertions, and the
  negative case proves which bit shows it.** `T13_LFUSE` bit 6 is EESAVE, which
  no assertion in `test_fuses.c` reads — so an lfuse disagreeing with the
  Makefile in that bit alone passes all 46 checks. The gate builds exactly that
  binary and requires the round trip to catch it. The search is adaptive rather
  than pinned to that bit, so strengthening the checker later cannot turn this
  negative case into a false failure.
- **The gate builds its own binaries from the compile line `make -n` prints,**
  never from `test/avr/test_fuses` in the tree. The command is therefore the
  real one rather than a reconstruction, a stale checker cannot make the gate
  fail, and the two deliberately-broken builds cannot disturb the tree's.

Verified by reintroducing each defect on the real tree and restoring: a restored
`#define` fallback, a macro renamed on the Makefile side only (reported as one
rename, both halves named, not as two unrelated problems), an `#error` naming
the wrong variable, and a burned byte the checker does not verify.

**~~Classify the other `-D` macros with in-source fallbacks.~~ DONE
(2026-08-03).** 26 silent fallbacks down to 15, and every one that remains is in
a category with a stated reason. Three corrections to the specification below,
each of which changed what the work was:

- **The `SIM_*` / `MODEL_FUZZ_*` defaults are LOAD-BEARING, not laziness.**
  `FULL_HOST_DEFS` and `FULL_SIM_DEFS` are deliberately empty, so `make
  test-long` — the release gate — reaches the exhaustive workload by *not*
  overriding them. An `#error` there would have failed the release gate. Both
  groups now say so in the file, because the next reader to "finish the job"
  would otherwise repeat the mistake.
- **`PB0`/`PB1`/`PB2` and `F_CPU` are not severable injections at all.**
  `CBMC_DEFS` is the *only* thing that injects them; every other host build
  reaches the pin map through the shim. So the hazard is the reverse of the one
  described: the map exists in two or three copies and nothing compared them —
  change a pin in the shim and cbmc goes on proving the firmware against the old
  map, reported as a pass. Closed in C rather than with a gate: the canonical
  value is named once and `_Static_assert`ed against whatever was injected, so
  the copies cannot drift. Verified by drifting `CBMC_DEFS` PB1 1 → 3, which
  fails `test-cbmc` by name.
- **Two more instances of the shared-source/one-fallback shape turned up**, both
  the same shape as the `PIC_GPSIM_PROC` defect: `test_soak_pic.cc` is compiled
  for BOTH PIC parts and defaulted `PROC_NAME` to `p10f322`, and
  `test_config_pic.c` serves both lanes and defaulted its device label to
  `PIC10F322`. The per-part harnesses (`test_io`/`test_fault`/`test_lockstep`)
  may keep an adapter default for `PROC_NAME` precisely because they have one
  adapter per part — that is the structural difference, and it is now written
  down where the exception is taken.

Hardened to `#error`, each naming the Makefile variable its value comes from:
`FW_PATH` (6 sites), `F_CPU_HZ` (4), `MCU_NAME` (2), `PROC_NAME` (shared soak),
`PIC_DEVICE_NAME`, and all four soak knobs. The dead `PIC_*_DEFAULT_FW_PATH`
adapter macros went with them. `test_sim.c`'s ATtiny13a lane was the last place
a part was identified by the *omission* of a field — the tinyx5 rules injected
`MCU_NAME`/`F_CPU_HZ` and the 13a rules did not — and its `MCU_NAME` default was
the wrong spelling (`attiny13`) besides; both 13a rules now pass
`ATTINY13A_MCU`/`ATTINY13A_F_CPU`, byte-identical results.

What remains and why: 13 workload knobs (above), `PROC_NAME` in the three
per-part harnesses (adapter default is per-part correct), and `TRACE_VCD_PATH`
(reachable only under `-DTRACE`).

The original text follows.

**Classify the other `-D` macros with in-source fallbacks.** Split out
2026-08-03 from the item above, which closed the fuse-byte half. Measured today:
the Makefile passes 58 distinct `-D` macros and **25 still have `#ifndef`
fallbacks**. Most are legitimate workload knobs where a default is correct
behaviour (`SIM_*`, `MODEL_FUZZ_*`, `SOAK_PROGRESS_INTERVAL_MS`). Two groups are
not:

- **`SOAK_DURATION_MS`** (`test/avr/test_soak.c:78`). A severed injection
  reverts a soak to its in-source default — the C-side twin of the 43,200×
  overrun `v0.9.8` fixed on the make side, and the reason that overrun is worth
  taking seriously twice.
- **`PB0`/`PB1`/`PB2` and `F_CPU`** (`test/bypass_config_host.h:22-38`,
  `test/bypass_output_host.h:26-32`). These are pin numbers and a clock rate.
  Their fallbacks exist because CBMC ignores `-include` and needs them on the
  command line, so deleting them outright is not the fix — but a host test that
  silently substitutes its own pin map for the Makefile's is the same defect
  wearing different clothes, and the `#ifndef` is doing two jobs.
  `FW_PATH` (five files) is a third case: the fallback is a path, so a severed
  injection points a driver at an image that may not be the one under test.

Apply the `#error` treatment to the "must be injected" group, and where a
fallback has to stay for CBMC, say so in the `#ifndef` and make the reason
checkable. Effort: ~1–2 h. Impact: Medium — `SOAK_DURATION_MS` alone repeats a
defect this project has already been bitten by once.

**~~Axis E — nothing checks that a child still READS the environment its parent
sets.~~ DONE (2026-08-03).** Built as axis E of
`test/test_makefile_name_contract.py`; 98 channels over 154 write sites, every
one verified to reach a reader. 39 → 44 checks, 0.7 s → 2.3 s. Added
2026-08-03, from a live defect rather than a review. This is the
third interface in the same family as the four name-contract axes and the `-D`
item above, and the only one of the three that has already produced a wrong
answer in the tree.

Axis C harvests `NAME=value` only where it FOLLOWS the make word, and that
scoping is right: an assignment *before* a command is environment for that
command's child, not a claim about the Makefile's vocabulary. But nothing then
checks the other end. The child's read is renamed, the parent's write is not,
and the assignment becomes legal, silent and inert — the child falls back to its
own in-source default, which is axis C's failure mode with a different owner.

Measured: `test/pic/gpsim_wrapper_common.sh` had its `PIC_GPSIM_PROC` read
renamed to `PIC10F322_GPSIM_PROC` while all four Makefile writers kept the old
spelling, so `make pic10f320-test-gpsim` ran the 256-word part's HEX on a
`p10f322` device model and reported `RESULT: PASS`. Fixed, and
`test/test_gpsim_wrappers.sh` now probes both public lanes end-to-end — but that
is one gate for one channel, not a contract.

*Two things learned while fixing it, both of which shape the item.*

- **The gate that existed for this was severed the same way.** Its comment said
  "if this regresses, the PIC10F320 lanes silently simulate a PIC10F322", and
  the rename rewrote the check's own probe to supply the new name. A gate that
  sets the input it means to observe cannot see its producer disappear. Any
  axis-E gate must read the value from the producer, never inject it.
- **Axis D's vocabulary actively pointed at the defect.** Its known-name set was
  make variables only, so prose naming a shared env channel read as severed and
  the only accepted spellings were part-scoped make-variable names — which is
  the rename that caused this. Fixed the same day by unioning in
  `env_channel_names()` (`NAME=` prefixes in recipe statements). That closes the
  false positive; it deliberately does **not** check that anything reads the
  name, which is this item.

*Scope, measured on the current tree:* 121 env-channel names are written from
Makefile recipe prefixes. A probe requiring each to be read somewhere under
`test/` or `scripts/` (following `.` sourcing and Python imports, since
`AWK` reaches `check_stack_depth_pic.sh` through a wrapper and
`BYPASS_MODEL_FFI` reaches `model_step_ffi.py` through an import) reported
exactly one severed name — `PIC_GPSIM_PROC`, the defect above. So the surface is
small and the false-positive rate looks survivable, which is the property that
made axes C and D affordable.

Two design notes for whoever builds it. The reverse direction (a script reading
an env name nothing sets) is NOT the same check and should not be bundled: a
script legitimately reads names an operator sets by hand. And a transitive
reader search is required, not optional — a direct-read-only version reports
both examples above as severed on a correct tree.

**Both design notes held.** The reverse direction is not bundled, and
transitivity is load-bearing exactly as predicted — `AWK` reaches its read
through a wrapper, `BYPASS_MODEL_FFI` through a Python import.

**Four things the specification did not anticipate.**

1. *Separating a channel from a shell local needs a real recipe tokenizer, not a
   word split.* This is the whole difficulty of the producer side, and it cuts
   both ways: `NAME=$(MAKEVAR)` — the shape of every channel here, including the
   severed one — reads as a command substitution to a naive splitter and
   disappears from the harvest, while `rc=$$?` and `out=$$(…)` read as channels.
   The tokenizer is quote- and expansion-aware, so `$(call f,a,b)` is one token
   and a `;` inside a quoted awk program does not end a statement. The
   discriminator is then structural rather than conventional: a prefix is an
   assignment *followed by a command in the same statement*; a local is an
   assignment that is the whole statement. Measured, that rule alone separates
   them perfectly — 98 channels, none lowercase, and every lowercase name among
   the 40-odd locals it drops. No naming convention is relied on, so a channel
   spelled in lowercase would still be checked.
2. *The check must be per LINK, not per name.* Discovered by a negative case
   coming back vacuous. `ATTINY202_FUSE_WDTCFG` is written at five sites: four
   to drivers that read it through a computed prefix, one to the fuse reader's
   own unit test, which names it literally. Satisfying the *name* lets breaking
   the computed prefix — which severs all four real consumers at once — pass on
   the strength of the unit test. Every write site is now its own link.
3. *A channel can hide behind a make variable.* `$(XT_FUSE_ENV)` expands to
   seven `ATTINY202_FUSE_*` assignments that appear nowhere in the recipe text.
   A lone `$(VAR)` in prefix position is expanded through `make print-` and
   walked.
4. *A reader can BUILD the name instead of writing it.* `attiny202_fuses.py`
   computes `"ATTINY202_FUSE_" + name` over a table, so no literal spelling of
   any of the seven exists in the file that reads them. Axis A already needed
   this shape for `mkv part_"$n"`; the environment has it too. Computed reads
   are counted separately in the summary line rather than blessed silently.

*Scope, stated because it is narrower than "every env channel":* Makefile recipe
prefixes. Shell scripts write 14 prefixes between them, dominated by shell
built-ins that happen to be uppercase (`IFS`, terminal colour codes), so a
second discrimination pass does not pay — and Makefile-to-script is where the
defect was. An unresolvable consumer **fails** rather than being skipped, since
a skipped check that reports as a pass is this gate's own defect class; the two
genuine external consumers (`PYTHONPATH`, `PYTHONWARNINGS`, read by CPython at
startup) are listed with reasons and expire like every other exemption.

Verified against seven mutations, each confirmed to fail and confirmed to fail
for its own reason: the original defect re-created (rename the sourced wrapper's
read, keep the Makefile writes); a directly-invoked child stopping its read; a
transitive child stopping its read; the computed prefix changing; an
unresolvable consumer; a stale allowlist entry; and a tokenizer that returns
nothing. All seven are applied to the gate's own text cache, so no file in the
repository is modified to run them.

**~~Record the `v0.9.8` byte-identity verification as evidence, not just as a
claim.~~ DONE (2026-08-03).** `scripts/verify-rename-identity.sh`, run from
`scripts/make-release.sh` step 1 and retained as
`release/<version>/RENAME_IDENTITY.md`. Measured on the current tree: **18
identical, 0 differ, 0 missing, 0 added**.

Built as specified — hash every image against the entry for its old name in the
signed `release/v0.9.7/SHA256SUMS`, through the `release/README.md` mapping —
with four decisions the item did not anticipate:

- **The script holds no version of its own.** It reads BOTH versions out of the
  rename table's own header (`| up to \`v0.9.7\` | from \`v0.9.8\` |`), so it
  says "not applicable" and does nothing for any other release. The
  "deliberately not a standing gate" requirement is then a property of the
  script rather than a note asking a future maintainer to remember to remove a
  call. Delete it when the table stops naming the current release.
- **It runs in step 1, not at staging.** The natural place to compare is where
  the hashes are written — on the far side of the 24-hour soak. A changed byte
  would then cost a day to discover. Nothing about the comparison needs the
  staged copies, so it runs immediately after the build.
- **Not under `evidence/`.** That directory's contents are pinned exactly by
  `RELEASE_EVIDENCE_FILES` for EVERY release, so a file only one release
  produces would fail the *next* release's qualification verifier. It is staged
  beside the images instead, and named in `MANIFEST.md` and the per-release
  `README.md`.
- **The mapping is parsed, never restated.** A second copy of eighteen renames
  in a verifier would be a third spelling of the same fact, free to drift from
  the table users actually follow — which is the defect class this release spent
  itself removing. Both stage vocabularies come from the document too, since the
  rename is what retired the old tokens and they exist nowhere else.

Verified by hand on all five paths: the real 18-image comparison passes; a
single changed byte reports `DIFFERS` with both digests and fails the release; a
missing image reports `NOT BUILT`; an image with no `v0.9.7` counterpart is
listed as added rather than silently counted; and a non-matching version reports
"not applicable" and exits 0. There is deliberately no standing gate for the
script itself — it is fail-fast, fail-closed one-shot release machinery, with
floors (≥10 mapped rows, ≥1 compared image) so it cannot pass vacuously.

**~~`scripts/make-release.sh` reads two tinyx5 programmer names and uses
neither.~~ DONE (2026-08-03).** `AVRDUDE_PART_X5[]` was built from `mkv part_85`
/ `mkv part_45` and read by nobody, while the manifest's ATtiny85/45 arm
hardcoded `prog="t85"` / `"t45"` — so the published flash command carried a
literal, and the `mkv` preamble was validating a value it discarded.

Wired the array in, as the better of the two directions the item offered: the
other four manifest arms all take their programmer name from Makefile truth.
Indexed by the part number the arm already computes
(`${AVRDUDE_PART_X5[${amcu#attiny}]}`) rather than by two more literals, with a
non-empty check so a `TINYX5` that stops covering an arm fails loudly instead of
publishing an empty `-p`.

**Re-pin yasimavr once the `SimLoop.run()` cycle-rewind fix ships.** Added
2026-08-02, after the upstream maintainer confirmed the defect reported from this
project and produced a fix.

`SimLoop::run(n)` pins the cycle counter to `first_cycle + n` on return, which
rewinds it when the last instruction overshoots; at `run(1)` that bills every
instruction 1 cycle. The ATtiny202 output tracer samples one cycle at a time, so
a 12 ms coil pulse traces as ~6 ms today (full account in `test/README.md` and
the `test_attiny202_delay_oracle.py` header).

When a release carrying the fix appears, bump `YASIMAVR_VER` /
`YASIMAVR_SDIST_SHA256` in `scripts/fetch_yasimavr.sh`, re-check whether patches
`0001`/`0002` are still needed, and rewrite the "KNOWN LIMITATION" block. A local
rebuild of 0.1.6 with the fix already showed the whole suite passing unchanged
and the pulse measuring 12.669 ms at single-cycle sampling, so this is expected to
be a pin bump, not a port.

Optional follow-on, and *not* a reason to delay the bump: an in-sim width
assertion becomes possible. It would be weaker than the existing oracle
(disassembly reads the compile-time truth exactly, while a trace carries ~0.67 ms
of tick-ISR preemption and the sampling granularity), so its only real value would
be as an independent cross-check that the image's compiled delay is what a running
device actually produces. Keep `attiny202-delay-oracle` as the gate either way.

Effort: ~1 h for the bump; ~2 h more for the optional cross-check. Impact: Low —
no new claim about the firmware, but it retires a documented simulator caveat and
removes a note that has already been wrong once.

**Extend the final-HEX return-stack oracle to the PIC10F322.** Added 2026-07-27
during the `pic10f320-merge-fixes` merge; **re-scoped the same day after the
device-geometry half was implemented and the real blocker was measured.**

`test/pic10f320/return_stack_oracle.py` is the stronger of the two
hardware-return-stack witnesses — it measures the shipped HEX rather than XC8's
emitted assembly, decodes every reachable word so it cannot miss a call, and
needs no toolchain annotations — but it covers the PIC10F320 only. The PIC10F322
has `check_stack_depth_pic.sh` alone, which is the weaker instrument (it trusts
XC8's `;;` annotation format and regex-matches the call opcodes).

*Done already:* the geometry is no longer hardcoded. `--program-words` is read
from the device pack's `ROMSIZE` (0x100 / 0x200 words; both parts declare
`PCBITS=0x9`, so the 9-bit architectural PC was already correct for both), it is
validated as a power of two within the PC space, and an image carrying program
data above the declared size is rejected outright — under-declaring is the
dangerous direction, because the fetch alias would fold a high PC onto a
different instruction and could report a *lower* depth than the truth. Ten
selftest checks cover both geometries.

*What actually blocks the 322,* which the original framing of this item missed:
its XC8 startup calls `clear_ram0`, clearing BSS through `CLRF INDF` in a loop
entered with FSR = base and W = last address + 1:

```
clear_ram0:  clrwdt
clrloop0:    clrf  indf        ; <-- rejected: FSR could select PCL or INTCON
             incf  fsr,f
             xorwf fsr,w       ; exit compares FSR against the CALLER's W
             btfsc status,z
             retlw 0
             xorwf fsr,w
             goto  clrloop0
```

The oracle rejects INDF writes because the FSR-selected destination could be
`PCL` (unmodelled computed control flow) or `INTCON` (asynchronous push). Making
this provably safe needs interprocedural constant tracking of **both** FSR and W:
FSR tracking alone is not enough, because the loop's exit depends on the caller's
W, and without that bound FSR wraps `0xFF -> 0x00` and reaches `PCL` (0x02), so
the rejection stands. The PIC10F320 image contains no `CLRF INDF` at all — its
BSS is small enough that XC8 does not emit the loop — which is exactly why the
asymmetry exists and why it is a toolchain/firmware property rather than
something the test side can adjust.

So this is a **dataflow-analysis project, not a parameterization task**: add an
abstract FSR/W domain to the traversal state and prove the clear loop's range
excludes the SFRs. Worth doing only if the second witness on the 322 is judged
worth that machinery — and it must be *sound*, since an approximate version
would be worse than the honest gap. High effort. No firmware change either way.
Note the two gates deliberately differ in what they enforce — the assembly gate
owns the policy budget (peak + reserve, depth read from the device pack), the
oracle owns the architectural limit — so this remains an extension of coverage,
not a consolidation.

**Formal verification of output drivers.** The output drivers (relay, mute,
CD4053) contain blocking delays and multi-step pin sequences. They are tested by
scenario-based simulation tests but are not formally verified — `test_cbmc.c`
currently proves the pure core only. A state-machine model of each driver could
be proved to: (a) never leave both relay coils energized simultaneously;
(b) always park coils low after a pulse; (c) never enter an invalid
mute/engage/bypass pin combination. The drivers are small enough (~30–60 lines
each) that a CBMC proof or exhaustive state-space check is feasible. The main
obstacle is that the drivers call a blocking delay, which CBMC cannot
symbolically execute; the workaround is to stub the delay as a no-op and verify
the pin sequence logic in isolation.

**Formal verification of blocking-delay safety.** The relay and mute output
drivers call a busy-wait delay inside `hw_set_bypass_state()` /
`hw_set_engaged_state()`. During this window the main loop cannot pet the
watchdog, and on AVR the timer ISR continues firing and integrating the debounce
counter. The `static_assert` guards (`CD4053_MUTE_DELAY_MS < RELEASE_THRESH`,
`TQ2_L2_5V_PULSE_MS < RELEASE_THRESH`) already prove the delay is shorter than
the release lockout, preventing counter drain to zero during the block. A CBMC
proof would formalize the full safety argument: (a) the blocking delay is always
less than the WDT timeout (trivially true — 12 ms << 250 ms — but made explicit);
(b) the delay is always less than RELEASE_THRESH (already `static_assert`ed, but
CBMC would prove the inequality holds for any future config change that passes
the assert); (c) the relay coil pulse duration is within the TQ2-L2-5V datasheet
limits. Low effort (~1–2 h). Makes the blocking-delay safety argument explicit
rather than implicit. Note the PIC and AVR shells reach this window differently
(polled loop vs ISR-driven), so state which shell each clause covers.

**Golden-model vs `model_step` cross-validation.** The golden model
(`test_logic_host.c`) re-implements the algorithm independently; `model_step.h`
delegates to the real firmware's `bypass_pure.c`. Both produce identical results
for the same input stream (verified implicitly by the lock-step co-sim and the
model proofs), but no test drives the same random input sequence through *both*
oracles and asserts byte-for-byte agreement. A small test comparing
`model_step.step()` against `test_logic_host.c`'s `model_tick_isr()` +
`model_main_step()` over a long random stream would provide a fourth independent
verification path, catching any discrepancy between the hand-written oracle and
the compiled firmware logic. This also becomes materially more valuable in a
merged tree, where the independent-oracle and direct-core roles must be kept
distinct on purpose.

**Full-path symbolic execution (KLEE with bounded loops).** The existing KLEE
path in `test_symbolic.c` proves per-step (single-tick) invariants — the
inductive step that, combined with valid initial states, implies whole-program
correctness. Extending this to multi-step verification would prove
whole-trajectory properties directly: e.g. "no input sequence of length N can
cause more than 1 toggle," or "from any valid state, any input sequence of
length N returns to a valid state." This provides an independent argument to the
exhaustive BFS proof in `test_model_check.c`, discharged by a different engine.
The infrastructure already exists (`-DUSE_KLEE`, `klee_make_symbolic`, and the
`test-symbolic-klee` target now links the real shipping core); the extension adds
a harness function with a bounded loop (e.g. `--unwind 50`). Medium effort
(~2–4 h). High value as an independent whole-trajectory proof.

**KLEE in CI.** `test-symbolic-klee` and `test-klee-build` exist, and the latter
runs in the default `test` aggregate — but that only proves the KLEE path still
*compiles and links*. No CI job actually runs KLEE (verified: no `klee` reference
in `.github/workflows/ci.yml`). A job using the `klee/klee` Docker image would
prove the symbolic path is genuinely exercised. ~2 h.

Updated 2026-07-27: this is now a *packaging* task with a known-good recipe, not
an open question. KLEE 3.2 is installed locally under `/home/linuxbrew/.linuxbrew`
— where the Makefile's `KLEE*` defaults already point — and
`make test-symbolic-klee STRICT_TOOLS=1` runs clean against the shipping core
(5,918 instructions, 14 completed paths, 0 partially completed). The proof is
therefore reproducible on one host and watched on none, which is precisely the
gap a CI job closes. Pin the KLEE and matching-LLVM versions in `TOOLCHAIN.adoc`
when it lands, as every other tool here is pinned.

**Cross-compiler verification.** The AVR firmware is built with avr-gcc 7.3. A
different compiler (newer avr-gcc, or clang targeting AVR if viable) could
optimise differently, potentially altering register allocation, ISR
prologue/epilogue timing, or the volatile-access ordering the sanity checks rely
on. Building with an alternative compiler and running the full simulation suite
would catch compiler-specific behavioural changes. Classic firmware targets
already rebuild on request, but nothing *compares* behavioural results between
compiler versions. A `test-cross-compiler` target that builds with
`CC=avr-gcc-12` (if installed) and re-runs `test-sim-attiny13a` would close this gap. See
also the broader multi-compiler matrix in Tier 3, of which this is the narrow
first step.

**Compiler optimization sensitivity test.** The firmware is built at a single
optimization level (`-Os` for size). Other levels could theoretically alter
register allocation, ISR timing, or the volatile-access ordering the sanity
checks and the ISR/main handshake rely on. A `test-opt-sweep` target would build
each variant at each level, run the full simulation suite against each, and
assert identical behavioural results — catching a regression where a change
introduces optimization-sensitive behaviour (e.g. a missing `volatile` that
happens to work under `-Os`). The Makefile already supports `CFLAGS` overrides
and the harness is variant-agnostic. Low effort (~1 h), good coverage value.

**Stack depth cross-verification.** Stack usage is currently verified two ways:
`-fstack-usage` static per-function frame analysis (`test-stack-bound`, 32 B
ceiling) and runtime high-water measurement with a canary pattern
(`test_stack_high_water_mark`). A third independent method — disassembly-based
call-graph analysis — would cross-reference the other two and catch any case
where the compiler's report disagrees with the actual binary. Approach:
`avr-objdump -d` the ELF, extract the call graph (CALL/RCALL), compute maximum
call depth, sum the per-function frame sizes, compare against the dynamic
measurement. The firmware is small enough (a dozen functions, max depth ~4) for a
simple script. Medium effort (~2–3 h). Note XC8 does not support
`-fstack-usage`; its `--callgraph` output is the PIC equivalent if this is
extended there.

**~~Negative `static_assert` verification.~~ DONE (2026-08-02).**
`test/test_static_assert_guards.sh`, wired in as `test-static-assert-guards` in
`TEST_GATES_EARLY`, so it runs in both `make test` and `make test-long`. 27
checks in 0.3 s: 24 guards counted, 9 mutations proven to trip one.

Built as specified — copy `src/` to a throwaway tree, break one thing, require
the build to fail with that guard's own message — with three corrections the
specification did not anticipate:

- **Break the guard's INPUTS, never the guard.** Mutating a `static_assert` line
  would prove only that the compiler implements `static_assert`. Breaking a
  threshold, a pin ordinal, the timer constant or a build flag is what a real
  regression looks like, and catching it there is the guard's actual job. One
  mutation is therefore not a source edit at all: dropping `-fshort-enums` from
  `CFLAGS` is the realistic way the enum-width guards get defeated, and no edit
  to `src/` can express it.
- **Mutations alone cannot detect a DELETED guard, and the first version of this
  file proved it by missing one.** Guards come in families sharing one
  diagnostic — three enum-size asserts all say `use -fshort-enums`, seven pin
  asserts all fail the same build — so deleting one leaves a sibling to trip the
  mutation and the deletion scores as a pass. Removing `sizeof(effect_state_t)`
  went unnoticed until a probe went looking. Fixed by a census: per-file guard
  counts are pinned, so a deletion fails and so does an addition, which forces
  someone to decide whether the new guard needs a mutation.
- **Three preconditions have to be checked, not assumed**, or the whole exercise
  measures nothing: the unmutated tree must compile (otherwise every "it failed"
  is unattributable), each mutation must actually change its file (`sed` patterns
  rot — `TIMER0_OCR0A_1MS` is defined with leading whitespace inside an `#if`,
  and the first draft's pattern silently matched nothing), and the failure must
  carry the guard's own message (or an unrelated compile error scores as a pass).

Validated against a doctored copy of `src/` — reached through
`STATIC_ASSERT_SRC`, which exists only so the watcher can be tested without
editing the firmware it watches. Every failure mode fires with its own
diagnostic: guard deleted, guard weakened `>` to `>=`, message reworded,
`#define` reindented out from under a mutation, a shell dropping the shared
header's `#include`, a sixth invariant added, and the pristine tree broken.

Surfaced one finding for the firmware owner, filed separately below as
**"`bypass_compile_checks.h` claims a reach it does not have"**. The gate
records the divergence explicitly (`SHELLS_WITH_OWN_COPY`) so it is counted
rather than blessed, and a fifth shell that does neither now fails.

**`bypass_compile_checks.h` claims a reach it does not have.** Found 2026-08-02
while building `test-static-assert-guards`. **Firmware edit — for the owner.**

The header opens with:

```c
// Shared, MCU-NEUTRAL compile-time contract for the debounce thresholds.
// Included by every hardware shell (bypass_mcu_avr_classic.c,
// bypass_mcu_pic10f322.c) so the invariant lives in ONE place and cannot drift
// between shells.
```

Both halves of that sentence are wrong, in opposite directions:

- **The list is short one shell.** `src/bypass_mcu_avr_xt.c` includes the header
  too (added with the ATtiny202 target; the comment was never updated). Three
  shells include it, not two — so the reader checking whether the ATtiny202 is
  covered is told it is not.
- **"every hardware shell" overstates it.** `src/bypass_mcu_pic10f320.c` is a
  hardware shell and does not include it. It carries its own `RELEASE_THRESH`,
  `PRESSED_THRESH`, `DEBOUNCE_COUNTER_MAX`, its own `static_assert` shim, and
  its own copy of all five invariants — with different message text
  (`"RELEASE_THRESH >= DEBOUNCE_COUNTER_MAX (i.e. UINT8_MAX)"` against the
  shared `"RELEASE_THRESH >= UINT8_MAX"`).

**First, what is NOT wrong**, because the obvious reading of the above is that
the PIC10F320 is out of compliance and it is not. Its self-containment is
deliberate, measured and documented: `docs/pic10f320_special_case.md` is the
authoritative statement, and `docs/pic10f320_feasibility.md` records that the
modular architecture overshoots 256 words by roughly 100. The merge plan states
it explicitly — "*Not* re-architecting the PIC10F320 firmware. It stays
single-file". That decision stands.

**Second, the duplicated thresholds are already guarded** — verified rather than
assumed, because the answer decides how urgent this is. The firmware↔core
equivalence lane host-compiles the real firmware (which uses its own `#define`s)
against `src/bypass_pure.c` driven from `bypass_config_host.h` (the shared
truth), so a drift in either constant makes the two step differently. Measured
on a scratch copy:

| Mutation to the 320's copy | Result |
| --- | --- |
| `RELEASE_THRESH` 25 → 30 | `FAIL: internal-state divergence at tick 0/18: fw(dc=30) model(dc=25)`, exit 1 |
| `PRESSED_THRESH` 8 → 12 | divergence on sequence 511, exit 1 |
| unmutated control | 266,144 sequences, 0 divergences |

So this is a **documentation defect, not a correctness defect**. It matters
because the comment is the thing a reviewer reads to decide whether the
threshold contract is centralised, and it currently answers that question
wrongly in both directions.

## Fix A — correct the comment (required; this is the actual defect)

In `src/bypass_compile_checks.h`, replace the opening paragraph with something
that states the real reach and why one shell is outside it. Suggested wording:

```c
// Shared, MCU-NEUTRAL compile-time contract for the debounce thresholds.
// Included by the three MODULAR hardware shells -- bypass_mcu_avr_classic.c,
// bypass_mcu_avr_xt.c and bypass_mcu_pic10f322.c -- so the invariant lives in
// ONE place for all of them and cannot drift between them.
//
// bypass_mcu_pic10f320.c is deliberately NOT among them: at 256 words of flash
// it is a single self-contained file that shares no headers with src/, and it
// carries its own copy of these five invariants. That is a documented design
// decision, not an oversight -- see docs/pic10f320_special_case.md. Its copy is
// held to these values by the firmware<->core equivalence lane, which compares
// the real firmware against bypass_pure.c driven from the shared config, so a
// drift in either threshold fails that lane rather than passing silently.
//
// MCU-SPECIFIC compile-time checks stay in their shells: the -fshort-enums size
// asserts, the F_CPU / _XTAL_FREQ checks, and the per-MCU pin-map pinning.
```

`test-static-assert-guards` already pins the rest: it fails if a shell stops
including the header without being recorded in `SHELLS_WITH_OWN_COPY`, and its
census fails if the count of invariants changes.

## Fix B — optionally let the 320 share the two constants (measured: free)

Strictly optional, and it does **not** re-architect anything: it removes two
duplicated *constants*, not the inlined algorithm, so the seam
`docs/pic10f320_special_case.md` §2 describes is untouched. The file stays
single-TU and links nothing new — `RELEASE_THRESH` and `PRESSED_THRESH` are
defined *outside* `bypass_config.h`'s `#if defined(__AVR__)` block, so a
non-AVR compiler picks up those two macros and nothing else.

Edits to `src/bypass_mcu_pic10f320.c`:

1. after `#include <stdint.h>`, add

   ```c
   #include "bypass_config.h"        // PRESSED_THRESH / RELEASE_THRESH
   #include "bypass_compile_checks.h" // the shared threshold invariants
   ```

2. delete its `#define RELEASE_THRESH (25U)` and `#define PRESSED_THRESH (8U)`
   (with their comments — the shared header's are better);
3. delete its `#define DEBOUNCE_COUNTER_MAX (255U)` and the MISRA-`UINT8_MAX`
   rationale comment above it, both duplicated verbatim from the shared header;
4. delete its five `static_assert` invariants;
5. keep its local `static_assert` shim, or drop it for
   `#include "bypass_static_assert.h"` — that header is just `<assert.h>` plus
   the same alias, and the file already includes `<assert.h>`.

No include-path change is needed: XC8 compiles the firmware from `src/`, and
quoted includes resolve relative to the including file's directory. The host
harnesses reach the firmware through `#include "../../../src/…"`, so their
nested quoted includes resolve the same way.

**Measured on a scratch copy of the tree, all three variants** (XC8 v3.10,
DFP 1.9.189, the pinned release toolchain):

| Variant | Flash before | Flash after | Emitted HEX |
| --- | --- | --- | --- |
| `OUTPUT_CD4053_SIMPLE` | 220/256 words | 220/256 | **byte-identical** |
| `OUTPUT_CD4053_WITH_MUTE` | 241/256 | 241/256 | **byte-identical** |
| `OUTPUT_TQ2_RELAY` | 244/256 | 244/256 | **byte-identical** |

Byte-identical images matter for more than reassurance: `test/pic10f320/expected_images.sha256`
pins the whole matrix, so this change needs **no rebaseline**. The equivalence
lane also passes unchanged on the modified copy (266,144 sequences, 0
divergences, 66/66 model states).

Net effect: −21 lines, one fewer place for the thresholds to drift, and the
`SHELLS_WITH_OWN_COPY` entry in `test/test_static_assert_guards.sh` becomes
empty — delete it and the shells loop covers all four with no exception.

After either fix, re-run `make test`; after Fix B also
`make test-pic10f320-expected-images` and `make pic10f320` to confirm the hashes
still match.

Effort: Fix A ~10 min. Fix B ~20 min plus the re-runs. Impact: Low-Medium —
no behaviour change, but it corrects the one document a reviewer would use to
decide whether the threshold contract is centralised.

**Clock drift fine-grained sweep.** `test_oscillator_drift_tolerance` checks only
the ±10% endpoints (drift factors 0.9 and 1.1). An exhaustive sweep in finer
increments (1% steps) would confirm no threshold change or off-by-one latency
lurks at any intermediate frequency. The concern is narrow but real: the
PRESSED_THRESH=8 tick boundary is calculated for the +10% worst case, and
intermediate frequencies could expose a rounding or tick-count edge case the
endpoints alone miss. Mechanically simple: loop over drift factors, reset sim,
measure latency, assert <10 ms.

**~~Stuck-switch long-duration test.~~ DONE (2026-08-02).**
`test_stuck_switch_no_recovery()` in `test/host/test_logic_host.c`, on the
golden-model path as specified. Six simulated hours per case (`21600000` ms,
knob `MODEL_STUCK_SWITCH_DURATION_MS`), two cases, 0.2 s of real time — so it is
deliberately NOT workload-scaled: shrinking it in the fast lane would leave
`make test` asserting something weaker than the caveat it enforces, and would
save nothing worth having.

**One correction to the item's premise, and it matters for how the test is
read.** The framing assumed duration is where the strength comes from. It is
not. This model is finite-state with a counter bounded at `RELEASE_THRESH`, so a
held-low input reaches its fixed point within `RELEASE_THRESH` ticks and every
millisecond after the 25th revisits the same state. Measured while looking for a
defect only this test catches: deleting the integrator's saturation — the
counter wrap this looks like it exists to catch — is *already* caught by sixteen
other assertions in the file, because a wrapping counter misbehaves inside the
existing 5 s hold too.

What the test actually adds is the shape of the assertions:

- the **power-on-stuck** case is driven over time at all. `test_power_on_pressed`
  checks the instant after `init()` and nothing after it, so "a pedal that boots
  with a jammed switch never toggles on its own" was asserted for exactly one
  tick;
- invariants are checked **every tick** rather than at the end, so a transient
  excursion that settles back cannot hide behind a final state;
- the debounce counter is **pinned to its saturated value**, which no other test
  asserts;
- **recovery once the fault clears** is asserted, so "no recovery" cannot decay
  into "left corrupt" — the design doc promises the first, not the second.

The hours buy one thing beyond that, and it is worth the 0.2 s: a standing guard
against a future change introducing an accumulator that is *not* bounded, which
is the only defect class a long run can see and a short one cannot.

Subject is the golden model, i.e. the ORACLE, not the firmware. The shipping
integrator is already covered more strongly than any run can manage —
`test/formal/test_cbmc.c` (C1) proves `debounce_integrate()` saturates for every
admitted input. The gap was that the simavr tests judge the firmware by
comparing it against this model, so a model that drifted would make a firmware
that drifted look right.

**WDT pet frequency measurement.** `test_watchdog_not_tripped_normally` confirms
the WDT does not fire during normal operation, but does not verify the *rate* at
which it is petted. During steady-state idle the pet should occur at
approximately 1 kHz (once per 1 ms tick, gated on AVR by the `timer_isr_called_`
handshake). Verifiable by counting pet-site executions over a known simulated
window (e.g. 95–105 over 100 ms). Catches a regression where the handshake is
broken in a way that still allows occasional pets. Applies to both the AVR
handshake and the PIC polled loop, with different expected counts — note the PIC
loses ticks during blocking actuation, so its expectation must budget for that.

**Interrupt-free window measurement.** During normal operation the AVR firmware
should never disable interrupts: `sei()` is called once at the end of `init()`
and never disabled in steady state. The only `cli()` calls are in `init()` and in
the forced-reset fault path. A simulation test would monitor the I-bit in SREG
across a representative workload (idle, press, toggle, release, repeated taps)
and assert it stays set outside `init()`. Catches a regression introducing a
`cli()` without a matching `sei()`, which could cause missed ticks or a WDT
timeout. Low effort (~1 h). Confirms a design invariant currently enforced only
by code inspection.

**Multi-press boundary-case regression tests.** Existing tests cover the
principal press-release scenarios well, but three boundary combinations are not
explicitly asserted: (a) two back-to-back PRESSED_THRESH-minus-one intervals
(total 14 ms > PRESSED_THRESH = 8 ms, but the counter never holds at threshold
long enough because each interval drops before the next rise) — must produce zero
toggles; (b) release-bounce landing exactly when the lockout counter is at 1 (a
single-tick press during drain raises the counter to 2, then drain resumes to 0)
— must delay re-arm by one tick but still re-arm correctly; (c) a
maximum-frequency tap train at exactly PRESSED_THRESH + RELEASE_THRESH intervals
(33 ms apart), the fastest clean press the algorithm can register, repeated 10–20
times to verify no drift or missed taps at the rate limit. These exercise the
integrator's saturating behaviour at the exact tick boundaries that matter. Add
to both the golden-model regression and the instruction-accurate firmware
confirmation. ~3–4 h total.

**Power-on-pressed simulation gap.** The simavr harness sets the footswitch IRQ
*before* the firmware starts (via `sim_reset(1)`), correctly exercising
`debounce_init_context(PIN_STATE_LOW)`. The known limitation: after a WDT reset,
simavr clears PINB to 0x00, inconsistent with the externally-driven IRQ level.
The golden model and model check both cover the power-on-pressed logic
exhaustively, so this is a simulator-fidelity gap rather than a coverage gap.
Closing it needs either a simavr patch preserving IRQ-driven input levels across
reset, or re-establishing the footswitch IRQ drive immediately after each reset —
option two is mechanically feasible in the harness, and the WDT-backstop test
already partially works around it.

**Power-supply ramp-up analysis.** The design assumes clean 5 V at power-on, but
real LDOs with large output capacitors can produce slow-rising VCC (tens of ms).
A slow ramp could let the MCU begin executing before the internal oscillator
stabilises or before the footswitch pull-up reaches a valid logic high. simavr
does not model voltage ramps, but the concern can be addressed indirectly:
(a) clock-prescale and GPIO setup are the first operations in `init()`, so verify
they complete correctly under a bogus initial register state (inject pre-init
register corruption before the firmware starts); (b) confirm by worst-case
analysis that the 64 ms SUT delay covers the LDO ramp (check the LP2950/AP7375
datasheet startup time against 64 ms). Item (b) is a documentation task and pairs
naturally with the Tier 2 datasheet-citation item.

**~~Fail-closed gate on the names other files exchange with the Makefile —
`print-<VAR>` reads, documented `make <goal>` targets, <!-- name-contract: exempt (<goal> is generic) -->
`make VAR=value` overrides, <!-- name-contract: exempt (VAR=value is the generic schema) -->
and variables named to human
readers.~~ COMPLETE (all four axes, 2026-08-02.)** Added 2026-08-01 while doing
the variable-prefix rename in `v0.9.8`; widened three times on 2026-08-02 —
first after the same class was found severed on the goal axis, then after it was
found severed on the override axis (where it had already burned a >10-hour run),
then after a meta-review of the whole release found ten more surfaces naming
removed variables, two of them instructing a reader to type one.

One defect, four axes. Nothing asserts that the Makefile names other files
*speak* are a subset of the names the Makefile actually *defines*, so a rename
severs the link silently and every gate stays green.

*Axis A — variables (**done**).* `print-%` is a pattern rule (`Makefile`,
`@echo '$($*)'`), so it matches any name. Ask it for a variable that no longer
exists and it prints an empty line and exits 0.

That is not hypothetical: the `v0.9.8` rename left three `mkv` calls in
`scripts/make-release.sh` pointed at removed names (`MCU`, `LFUSE_X5`,
`HFUSE_X5`). Nothing failed. The effect would have surfaced only in the
published artifact — a `MANIFEST.md` with empty ATtiny13a and tinyx5 fuse
bytes, and one image path composed as `bypass--<stage>.hex` — at the end of a
24-hour release run. It was caught by an ad-hoc sweep, not by the suite, and
`make test` cannot catch it because it never executes the release script's
variable preamble.

*Axis B — goals named in documentation (**done**).* Same severance, worse outcome, because
a reader runs these by hand and gets `No rule to make target`. The `v0.9.8`
prefix rename left 15 dead goal references in `docs/pic10f320_validation.md` —
a document explicitly framed as *current* qualification evidence, not history —
including its entire §7 "Reproducing any of this" block, where four of six
commands failed. One more sat in `docs/phase2_pic_shell.md`, and
`release/README.md`'s reproduce recipe told the reader to `git checkout v0.9.6`
and then run goals that only exist from `v0.9.8` on. Those were fixed by hand;
nothing prevents the next rename from re-creating them.

One further casualty surfaced in the 2026-08-02 meta-review, and it is the
sharpest argument for this axis: `test/README.md:68` named
`make test-sim-<variant>`, <!-- name-contract: exempt (quotes the defect) -->
which has no rule — the real goal is `test-sim-<variant>-attiny13a`. That is
precisely the defect the whole `v0.9.8` rename existed to kill, a goal
identified by the *omission* of its MCU field, surviving in a live document
because no sweep covered `test/README.md`. Note also that it is a goal
*schema* rather than a literal, so the gate must either resolve `<variant>`
against `VARIANTS` or skip placeholder forms deliberately — not silently fail
to match them, which is how it went unnoticed.

*Axis C — command-line overrides.* The reverse direction of axis A: instead of a
file *reading* a Makefile variable, a file *sets* one. `make test-soak
SOAK_DURATION_MS=2000` defines a make variable named `SOAK_DURATION_MS`; if the
recipe reads `$(AVR_SOAK_DURATION_MS)`, the override is inert and the default
applies. Make says nothing, because an override naming no existing variable is
legal.

Found 2026-08-02, in the tree, having already cost a run.
`test/run_mutation_tests.sh:236` still passed the pre-rename `SOAK_VARIANT=` /
`SOAK_CHIP=` / `SOAK_DURATION_MS=` / `SOAK_LIVENESS_INTERVAL_MS=` to `make
test-soak`, so the classic-AVR WDT-pet mutant asked for 2 s of simulated time
and silently got `AVR_SOAK_DURATION_MS`'s 24 h default — 43,200×. A local
`ci-local.sh` run sat in that single mutant for over 10 hours before being
killed. Both CI jobs reaching this row (`ci.yml:336`, `:643`) declare no
`timeout-minutes`, so they would have been cancelled at GitHub's 6-hour job
limit.

Four guards missed it, each for a different reason, and the set is worth
recording because it explains why this class needs its own gate: the soak-timing
contract's `static_assert` compares the *defaults* (60000 <= 86400000), so the
build is clean; the mutant is still correctly killed, just ~43,000× too slow, so
the failure mode is a hang rather than a wrong answer; mutation runs only in
`test-long`; and the mutation harness wraps no mutant in `timeout`.

*Axis D — variables named to human readers (**done**).* The variable-side twin of axis B,
and the one this item kept missing because each earlier widening was scoped to
the names *that* rename had just touched. A comment, a README or a `make`
diagnostic names a variable; the rename moves it; the prose keeps recommending
the dead spelling. Where axis C is a *file* setting an inert variable, this is a
*document telling a person* to set one, and the person gets no error at all —
make accepts the assignment and ignores it.

Found 2026-08-02 by a meta-review of the finished release, ten surfaces:

- `Makefile:3089` — the `test-flash-budget` guard reads `$(ATTINY13A_MCU)` but
  its failure message said `requires MCU=attiny13a`. Worst of the set: it is the
  *gate's own advice to a user who has already failed*, and following it changes
  nothing. `test/test_flash_budget.sh:171` asserted that exact substring, so the
  regression was pinning the wrong advice in place — a gate can entrench this
  class as well as catch it.
- `Makefile:4216` — "`PIC320_{FAULT,IO,LOCKSTEP,TARGET}_VARIANT` can each be set
  directly on the command line", an instruction naming four removed variables.
- `Makefile:4546`, `scripts/ci-local.sh:249`, `test/test_ci_local_routing.sh:38`
  — descriptive `PIC320_*` prose; code beside all three was correct.
- `README.md:109` — told readers the PIC10F320 lane uses `PIC320_*` variables.
- `test/test_avr_build_rebuild.sh:94`, `test/test_workload_rebuild.sh:99`,
  `test/test_flash_budget.sh:85` — inert `MCU=attiny13a` (also axis C).

Worth recording honestly: none of these mis-built anything. `ATTINY13A_MCU` is a
plain `=` (`Makefile:165`) whose default equals the value the dead overrides
passed, and a plain `=` also resists the environment. The cost of axis D is
misdirection, not wrong output — which is exactly why no gate would ever notice
it, and why the harvest has to be textual.

**Axis C is DONE (2026-08-02).** `test/test_makefile_name_contract.py`, wired in
as `test-makefile-name-contract` in `TEST_GATES`, so it runs in `make test`.
Verified by reproducing the original defect: reverting the mutation row to its
pre-rename `SOAK_*` spellings makes the gate name all four severed overrides and
fail. 9 checks, 72 overrides verified on a clean tree.

Three things it learned that were **not** in the specification below, recorded
because they invalidate parts of it:

1. *The prototype would not have caught the defect it was written for.* The
   spec says "harvest every `NAME=value` token from lines invoking make". The
   `v0.9.8` defect lived in a **mutation table row**:
   `test/run_mutation_tests.sh`
   stores make command lines as the third tab-separated field of a data row, and
   those rows contain no `make` token at all. Any harvest keyed on
   "lines invoking make" misses them entirely. The gate enumerates the mutation
   tables as a separate, named source, and asserts it found overrides there, so
   a table-format change fails loudly instead of silently dropping the only
   source that carries the motivating bug.
2. *`$(origin)` alone is the wrong oracle.* The spec is right that
   non-emptiness fails on defined-but-empty names, but `$(origin)` reports a
   **command-line-only input** as `undefined` — it is never defined in the file,
   it is *consumed*. `make release VERSION=v1.0.0` is the Makefile's own
   documented interface and `$(VERSION)` is read in the recipe, yet origin says
   undefined, so the Makefile's usage comment reads as severed. The contract is
   *defined **or** consumed*: `$(origin)` plus a `$(NAME)`/`${NAME}` dereference
   scan.
3. *Position disambiguates, and it retires most of the allowlist.* Overrides
   follow the make word; assignments **before** it are environment for make's
   children. Harvesting only the trailing position drops every fake-tool shim
   parameter (`FAKE_CC_LOG`, `FAKE_OBJCOPY_LOG`, …) and the `env` set handed to
   `make-release.sh`, because those were never claims about the Makefile's
   vocabulary. The allowlist went from the seven-plus names predicted below to
   **one** (`MUTATION_ALLOW_SKIP`), and the gate now asserts every exemption is
   still reached by the harvest, so exemptions expire instead of accumulating.

Two smaller ones: the Makefile must be harvested by *physical* line while shell
and YAML are continuation-joined (joining a recipe makes its whole body look
like one make invocation, so every shell local in it reads as an override); and
the harvest must stop at the first shell separator or redirection, or
`make … >/dev/null 2>&1; rc=$?` reports `rc` forever.

The Makefile side is an `origin-%` rule beside `print-%` — which had to live
there, exactly as predicted — plus a bulk `origins NAMES="…"` form so a whole
harvest resolves in one 27 ms invocation instead of one per name.

**Axis A is DONE (2026-08-02).** Folded into the same
`test/test_makefile_name_contract.py` rather than given its own gate: it shares
the oracle, the harvest machinery and the exemption discipline, and the gate was
never named for one axis. Verified by restoring the `v0.9.7` spellings in
`scripts/make-release.sh`, which makes it name all five severed reads with
their line numbers and exit 1. 22 checks total now, 64 variable queries
verified, 0.4 s.

Four things worth recording, two of which contradict the specification above:

1. *Anchoring on the make word — correct for axis C — is wrong here, and would
   have lost real sites.* Axis C needs the anchor because `NAME=` is a generic
   shape. `print-` is not: every non-query form in this tree
   (`--no-print-directory`, `-print-file-name`, `--print-data-base`,
   `--print-targets`) carries a hyphen immediately before `print`, so one
   lookbehind separates them and no `make` adjacency is needed. Requiring it
   would have dropped `test/test_workload_rebuild.sh:255`, which queries through
   a `run_make` wrapper and has no bare `make` token, and half of
   `scripts/ci-local.sh:368`, which spreads eight queries across a
   continuation. The two axes want different harvests, and assuming otherwise
   costs coverage silently.
2. *Axis A's contract is strictly stronger than axis C's.* Axis C accepts
   *defined **or** consumed*; a read must be **defined**. A command-line-only
   input such as `VERSION` is legitimate to set but useless to ask for — the
   query returns an empty line, which is the severance symptom itself.
3. *The historical-document exemption should be self-declared, not listed.* The
   spec (under axis B, below) predicted a hardcoded whole-file list. In fact
   nine markdown files already open with a banner calling themselves historical
   — `> **Historical decision record…**`, `**Status:** historical evidence`,
   `> …retained only for historical reproducibility` — so the gate keys on the
   banner. A new historical document is exempt the day it is written, deleting
   the banner puts the document back under the contract, and both directions are
   asserted. Only `CHANGELOG.md` is listed by name, because recording what names
   *used to be* is a changelog working correctly. This mechanism should be
   reused for axis B, where the exemption problem is described as the hard part.
4. *Computed names must be expanded, not skipped, and an unrecognised one has to
   fail.* `mkv part_"$n"` is the only one; it expands over `$(TINYX5)` to
   `part_85`/`part_45`, both checked. A skip would be invisible, so the gate
   fails on any computed prefix it has no expansion for.

The self-exemption is the other thing that had to be added, and it was not
foreseen: **the gate now harvests its own source.** That only became true when
the axis-C file was first committed — while it was untracked, `git ls-files` did
not list it and the exemption was accidental. (No longer possible: the harvest
reads the working tree rather than the index, per the closed Tier 3 item below.) Its docstrings necessarily quote
the removed names as examples and its negative-case fixtures build overrides on
purpose, so the file is excluded from both harvests, and the exclusion is
asserted to still be load-bearing. Any gate whose subject is *text* will meet
this; worth expecting on axes B and D rather than rediscovering.

**Axes B and D are DONE (2026-08-02), and the item is closed.** Built together,
as predicted, sharing one harvest pass over the same files and one exemption
mechanism. 35 checks now across all four axes, 0.6 s: 64 variable queries, 336
documented commands, 72 overrides, 65 variable mentions.

Both found a live defect on the first clean run — `.gitignore:44` named
`pic-test-soak`, a goal the `v0.9.8` rename removed, in the comment explaining
which goal produces the file it ignores; and a `Makefile` comment described the
PIC soak's knobs as a family that no variable belongs to.

Corrections to the specification above, recorded because two of them invalidate
design notes that were written with some confidence:

1. *The ">2 minutes" figure for `make -rRn --print-data-base` was wrong, and the
   reason matters more than the number.* The parse costs **0.024 s** nested and
   0.1 s cold. What the earlier measurement caught was the **worktree flock**:
   under `-n` make still executes recipe lines containing `$(MAKE)`, and the
   serialization wrapper's is one, so a standalone parse waits on the lock
   exactly as `make -s print-<VAR>` does. Measured directly: against a 6 s lock
   holder the parse took 5.7 s, and inside `make test` — where
   `_MAKE_SERIAL_LOCK_HELD` is inherited and the wrapper is bypassed — 0.024 s.
   The static-harvest fallback was never needed, and would have been strictly
   worse: make's own data base is the only source that carries the
   `$(eval $(call ...))` families, so a textual harvest of rule heads would have
   reported every documented use of `attiny85-program` or
   `test-sim-cd4053_simple-attiny13a` as missing.
2. *Axis D's prefix-vocabulary premise was wrong.* "Scoping to that vocabulary
   is what keeps the false-positive rate survivable" — it is not, because the
   vocabulary is shared. `SOAK_PIDS`, `MUTATION_MAKE`, `RELEASE_THRESH`,
   `FW_PATH` and 150 others carry the project's prefixes and are shell locals,
   C macros and CI environment keys. A prefix cannot tell a Makefile variable
   from any of them, and the first measurement of the specified sweep returned
   154 candidates of which 1 was real. Two changes make it work: harvest
   **prose only** (documentation, and comments in code — never executable
   lines), and treat a family reference as a **prefix query** rather than a
   name. `PIC320_*` asks whether any known variable begins with `PIC320_`;
   testing the stem as a whole name reports `AVR_SOAK_*` and `XT_FUSE_*` as
   severed, since nothing is literally called `AVR_SOAK`.
3. *Axis B's precision problem is far larger than "some false positives", and
   the fix is context rather than vocabulary.* English follows the word "make"
   constantly. A harvest reading every line containing `make` returned **881**
   distinct tokens — "sure", "the", "a", "and" — against about a dozen real
   ones. Three rules take that to zero: read only command contexts (fenced
   blocks and backtick spans in documentation, command lines in code, backtick
   spans in comments); require the make word to **open** its fragment, so
   `apt-get install -y make util-linux` is not an invocation; and take only the
   **first** goal word, because what follows a documented goal is usually prose.
   Continuation joining matters here too, and for the opposite reason it did on
   axis C:
   <!-- name-contract: exempt (quotes the misparse) -->
   the apt list above only reads as `make util-linux` when its
   backslash is left unjoined.
4. *Goal-schema resolution is worth more than it looked, and it had to be
   fixed twice.*
   <!-- name-contract: exempt (quotes the defect) -->
   `make test-sim-<variant>` expands over `$(VARIANTS)` and every
   expansion must exist, which is what makes the `test/README.md` casualty
   catchable. The first implementation silently disabled itself: the shell
   redirection split ran before placeholder resolution and truncated the schema
   to `test-sim-`, turning a resolvable schema into an
   unrecognisable stub. A placeholder with no mapping now fails loudly rather
   than being skipped — which immediately surfaced two more schema forms
   (`<goal>`, `<target>`) that the sweep had never noticed.
5. *The exemption mechanism is per-line and per-block, as predicted, and the
   marker has to know which line it annotates.* A trailing marker exempts its
   own line; a marker that is the only thing on its line exempts the next
   non-blank one, which is the only way to annotate a C `#error` (whose trailing
   text would become part of the message) or a sentence wrapped across a comment
   block. A trailing marker deliberately does not reach forward, so annotating
   one table row cannot silently exempt the row beneath it. Twenty-one markers
   exist; every one must still suppress something or the gate fails.

Three of the four file-level exemptions predicted for axis B were needed and one
was not. Published release artifacts (`release/v*/`) are exempt by path rather
than by marker, deliberately: they are immutable records of what a past release
said, so nobody should be opening one to add a comment. Self-declared historical
documents reuse axis A's banner mechanism, which is what that prediction called
"the hard part" and turned out to cost nothing extra. `CHANGELOG.md` is exempt
by name on all axes, and `TODO.md` on axis D only — this file quotes every dead
spelling the four axes exist to catch, but its
<!-- name-contract: exempt (<goal> is generic) -->
`make <goal>` commands are still checked.

Ceilings, stated so the next reader does not over-trust the gate:

- Axis B checks only the first goal of a multi-goal command, and cannot see a
  goal named in running prose without `make` in front of it — "the per-variant
  `pic320` build" was a real `v0.9.8` casualty and is invisible to this.
- Axis D cannot distinguish a Makefile variable from a shell local or C macro
  sharing a project prefix, which is why five of the twenty-one markers say
  exactly that.
- Both are textual. Neither knows whether a documented command would actually
  succeed, only that its goal and its variables resolve.

A prototype sweep already works: harvest every `NAME=value` token from lines
invoking make across `test/`, `scripts/`, `.github/` and the Makefile's own
comments, and assert each name is Makefile-known.

**It must join backslash continuations before matching, and the first version of
it did not.** That version keyed on *physical* lines and reported five hits, all
benign. Re-run on 2026-08-02 with continuations joined, it found three more that
were real — the inert `MCU=attiny13a` overrides in axis D above:

```
test/test_avr_build_rebuild.sh
   89   make --no-print-directory -C "$repo" "$@" \
   ...
   94       AVR_FW=... FW_BASE=bypass MCU=attiny13a \
```

Five lines apart. Across `test/`, `scripts/` and `.github/` there were **zero**
physical lines containing both `make` and `MCU=`, and three once the
continuations were joined. This is the same "harvest regex quietly stops
matching" failure this item exists to catch, met on the prototype that produced
this item's own specification — which is the strongest possible argument for the
negative case demanded below.

With continuations joined the residual hits are these, and the gate has to
tolerate every one:

- Names passed through the *environment* to a script rather than to make. The
  recorded list of two was short by at least five: `MUTATION_ALLOW_SKIP` (read
  by `test/mutation_policy.sh`), `FAKE_COMPILER_LOG`, `FAKE_CC_LOG`,
  `FAKE_OBJCOPY_LOG`, `FAKE_HOST_CC_LOG` and `FAKE_HOST_RUN_LOG` (fake-tool
  shims), plus the `EXPECTED_LOCK` / `LOCK_ATTEMPT` / `REAL_FLOCK` set handed to
  `scripts/make-release.sh` via `env`. These need an allowlist; nothing in the
  Makefile can infer them.
- A **fourth** harvest-artifact class the earlier list missed: a line merely
  *mentioning* `scripts/make-release.sh` matches a bare `\bmake\b`, which is
  what drags in `RELEASE=`, `REPO_URL=`, `REAL_MAKE=` and the `env` set above.
  The make-invocation test needs a word boundary that `make-release.sh` fails.
- `override`-defined names (`RELEASE_EVIDENCE_FILES`, `Makefile:4825`), which a
  naive `^NAME=` harvest of *definitions* misses. Note that
  `test_release_qualification.sh:207` deliberately passes
  `RELEASE_EVIDENCE_FILES=bad` to prove the override is ignored — so a
  legitimate override may also be a deliberate negative test.
- Harvest artifacts, both fixable in the regex: shell locals assigned from make
  output on the same line (`XT_N=$(make -s print-...)`), and `-D` macros inside
  a quoted `SIM_DEFS='...'`.

The same check belongs in the Makefile itself if it can be done cheaply, since
it would also catch a hand-typed
<!-- name-contract: exempt (quotes the retired spelling this item is about) -->
`make test-soak SOAK_DURATION_MS=...` — which
is exactly what the Makefile's own comment recommended until 2026-08-02.

Design notes if picked up (the first three are ~~settled~~ by axes A and C and
are kept as the record of why, not as work):
- ~~**Use `$(origin)`, not non-emptiness.**~~ Several variables the scripts read
  are defined-but-empty by design (`XT_SOAK_COMBINATION_NAME`,
  `AVR_STACK_BUILD_DIR`), so a non-empty assertion produces false failures.
  `$(origin VAR)` returns `undefined` for a name the Makefile never sets and
  `file` for one deliberately set empty — verified, and it is the only oracle
  that separates the two cases. Held up exactly as written.
- ~~This needs an `origin-%` rule *inside* the Makefile, beside `print-%`.~~ It
  cannot be bolted on from an outer makefile that `include`s this one: the
  serialization wrapper (`_make-serialized-invocation`) intercepts goals it
  does not know and the invocation fails before the rule is reached. Confirmed
  when axis C built it; a bulk `origins NAMES="…"` form was added beside it so a
  whole harvest costs one invocation.
- ~~Harvest the variable names from both spellings.~~ `grep -oE
  'print-[A-Z][A-Z0-9_]*'` across `scripts/` and `.github/workflows/` finds
  most, but `scripts/make-release.sh` wraps them as `mkv <NAME>`, a bare word.
  Its `mkv part_"$n"` is a *computed* name and must be expanded over
  `$(TINYX5)` or excluded explicitly, not silently skipped. All correct, and
  under-scoped in one respect: restricting the harvest to `scripts/` and
  `.github/` would have missed `release/README.md`, a *published* document that
  tells a reader to query a variable. Axis A harvests every tracked file.
- **For axis B, resolve goals without running them.** `make -n <goal>` builds a <!-- name-contract: exempt (<goal> is generic) -->
  dependency graph and is far too slow to do ~90 times; it also blocks on the
  serial lock whenever a soak or `test-long` is running, which is exactly when
  someone is likely to run `make test`. Prefer a single `make -rRn
  --print-data-base` parse, cached once per invocation — but note that on this
  Makefile that command took over two minutes when tried on 2026-08-02, so
  measure it before committing to it. A static harvest of rule heads plus
  `.PHONY` members plus the `$(eval $(call ...))` generators is the fallback,
  and it must expand the generated families (`attiny$(1)`, `attiny$(1)-program`,
  `test-sim-<variant>-attiny<n>`) rather than report them missing.
- **Be honest about axis B's ceiling: it can only check goals it can
  recognise.**
  A harvest keyed on `make <goal>` catches commands, <!-- name-contract: exempt (<goal> is generic) --> which is the
  case that matters most because a reader runs those. It does *not* catch a
  goal named in running prose — "the per-variant `pic320` build" was one of the
  `v0.9.8` casualties, and it has neither the word `make` nor a hyphen suffix
  to key on. Widening the harvest to every backticked token that happens to
  look like a goal name will produce false positives (`pic320` is also a chip
  token, a directory fragment and a log-file stem). Recommend scoping the gate
  to `make <goal>` occurrences, and stating that scope in the gate's own header <!-- name-contract: exempt (<goal> is generic) -->
  so the next reader does not mistake it for total coverage.
- **For axis D, harvest the variable token, not a `make` line.** Axis C's
  harvest is anchored on a make invocation; axis D's cannot be, because its
  occurrences are prose (`README.md:109`), comments (`Makefile:4216`) and
  `echo` strings inside recipes (`Makefile:3089`) that never mention `make` at
  all. Key it instead on the shapes a variable name actually takes in this
  tree — `NAME=value`, `` `NAME` ``, `NAME_*`/`NAME=` inside a quoted
  diagnostic — restricted to the project's own prefix vocabulary (`ATTINY13A_`,
  `TINYX5_`, `AVR_`, `XT_`, `PIC_`, `PIC10F320_`, `PIC10F322_`, and the retired
  `PIC320_`/`MCU`/`SOAK_`/`PROGRAMMER` spellings). Scoping to that vocabulary is
  what keeps the false-positive rate survivable; a generic `[A-Z_]{3,}` sweep
  over prose will drown in C macros, register names and acronyms.
- **Axis D's highest-value target is `echo`/`$(error)` text inside recipes, not
  documentation.** A wrong comment misleads a reader who may already know
  better; a wrong *diagnostic* is read at the exact moment someone is confused
  and trusts it completely. `Makefile:3089` was that case. These are also the
  cheapest to check, because a recipe's strings sit beside the variables the
  same recipe dereferences — a rule whose body reads `$(ATTINY13A_MCU)` while
  its message says `MCU=` is locally inconsistent and needs no whole-tree
  knowledge to flag.
- **Guard against the gate entrenching the defect.** `test_flash_budget.sh:171`
  asserted the *wrong* diagnostic text verbatim, so the dead name had a
  regression test defending it, and correcting the Makefile alone would have
  turned that gate red. Any assertion that pins diagnostic text is a place this
  class can calcify; when axis D lands, sweep the existing assertions for
  hardcoded variable names too, not just the sources.
- **The allowlist is the hard part, and it is not "which file".** Live documents
  legitimately name retired goals in three distinct situations, all of which
  currently exist:
  1. Deliberate old→new redirect tables (`release/README.md`).
  2. Recipes pinned to an *older tag*, where the goal correctly does not exist
     in the current tree — `release/README.md`'s "Unified releases v0.9.6 and
     v0.9.7" block names `all13`, `pic`, `pic320-variants` on purpose, under a
     `git checkout` line.
  3. Quoted historical transcripts and real evidence paths
     (`docs/pic10f320_validation.md` lines 179 and 262: a captured `make: ***
     [pic320-test-equiv] Error 1` and
     `release/v0.9.6/evidence/pic320-test.log`, a file that exists under that
     name).

  So the exemption has to be per-block or per-line, not per-file — an explicit
  marker comment is probably cleaner than pattern-matching prose. Whole-file
  exemption is right only for the banner-marked historical records
  (`docs/pic10f320_merge_plan.md`, `docs/v0.9.6_post_release_polish.md`,
  `docs/pic10f320_feasibility.md`), which already declare themselves.
- Include the negative case on **all four** axes, per the house pattern: a
  deliberately bogus name must make the gate fail, so it cannot pass by
  harvesting nothing. The realistic failure mode is a harvest regex that
  silently stops matching, which is the same class of defect the gate exists to
  catch — and on axis C it is no longer hypothetical but *demonstrated twice*:
  the 2026-08-02 sweep needed three regex corrections before its five remaining
  hits were all genuine, and then the physical-line bug above hid three real
  ones behind a backslash. Make one axis-C negative a multi-line continued
  invocation specifically. For axis B add a second negative: an exempt block
  must stop being exempt if its marker is removed.
- Natural home is a new `test-makefile-name-contract` in `TEST_GATES`
  (host-only, no toolchain, so it belongs in `make test` rather than
  `test-long`), modelled on `test_release_provenance.sh`.

Related, and cheap to fold in: `test/run_mutation_tests.sh:1084` hand-composes
`${FW_BASE}-${PIC10F322_TAG}-cd4053_simple.hex` instead of reading
`print-PIC10F322_RELEASE_IMAGES`. The independent restatements in
`scripts/make-release.sh` and `test/test_pic_build.sh` are deliberate — they
exist to be cross-checked against Makefile truth — but this one cross-checks
nothing, it just needs a path, so the restatement buys nothing and cost exactly
the silent lane-disable that `v0.9.8` fixed.

Effort: **spent, item complete.** ~3 h for axis C against ~1 h predicted (the
three spec corrections are where it went, and each had to be found by the gate
failing on the real tree), ~1 h for A on estimate because C had already paid for
the oracle, and ~3 h for B and D together against ~2–3 h predicted. Total ~7 h.
Every axis cost more in *correcting its own specification* than in code, which
is the honest summary of this item: the sweeps were easy and knowing what they
should look at was not. Impact: High — no new
assurance about the
firmware, but it closes a silent-severance class on the interfaces between the
Makefile and the release orchestrator, the published documentation and the test
harnesses; those interfaces only ever get wider, and the class cost real time
four times over one release (a disabled mutation lane, a >10-hour hang, ten
stale surfaces a meta-review had to find by hand, and a severed per-variant map
that had been failing the PIC10F322 soak build since the stage rename).

A note on why this item keeps growing: every widening was found by looking, not
by a gate, and each time the scope of the *previous* sweep was the reason the
next one was missed — axis A swept `print-<VAR>`, so it did not see documents;
axis B swept `make <goal>`, so it did not see variables in prose; axis C swept <!-- name-contract: exempt (<goal> is generic) -->
make-invoking lines, so it did not see continuations, and then its own written
specification turned out not to see the mutation tables where the motivating
defect actually lived. That pattern is the argument for building the remaining
axes rather than sweeping by hand a fifth time — and for the house rule that
every gate carries a negative case, since on both finished axes the most
valuable single check is the one that reproduces the original bug and proves the
gate fails on it.

The pattern held to the very end. On axis A, in the mildest possible form: the spec's harvest scope (`scripts/`,
`.github/workflows/`) would have missed the *published* `release/README.md`, and
its make-word anchor — carried over from axis C without re-examining it — would
have missed two live query sites. Neither was a bug in the tree; both were
places the gate would simply not have looked. On axes B and D it was blunter:
the design note for B recorded a two-minute cost that was really a lock wait,
and the design note for D asserted a false-positive control (prefix scoping)
that does not work at all. Both were written from a single measurement.

That is the same shape as every earlier miss, which is why each axis now states
its own scope in its own header rather than inheriting the previous one's — and
why the closing verification on each was to reproduce the original defect and
watch the gate fail on it. All four now do.

---

## Tier 3 — platinum-level / nice-to-have

**~~The name-contract gate cannot see a file until it is committed.~~ DONE
(2026-08-03).** Added 2026-08-03,
from an observed instance rather than a review: `harvestable_files()`
enumerated `git ls-files`, so a NEW file was invisible to axes B, C and D until
it was tracked. `make test` therefore passed on the commit that introduced a
violation and failed on the next run — which is exactly what
`test/test_fuse_injection_contract.py` did, on two docstring lines that wrap
such that a line begins with the word "make" followed by an English word:

<!-- name-contract: exempt-begin (quotes prose that READS as a command; the
     goals named are English words, which is the entire point of the item) -->
> ... So a stale checker cannot
> `make this gate fail`, and this gate's negative cases ...

<!-- name-contract: exempt-end -->

Axis B's rule is that the make word must OPEN the command, which both lines
satisfied by accident of reflowing. (This item's own first draft then tripped the
gate the same way, quoting those lines — hence the marker above, which is the
honest use of one: the span really is not a command.)

Fixed as specified: `repo_files()` harvests `git ls-files` plus
`git ls-files --others --exclude-standard`, so a file that exists and is not
ignored is in scope whether or not it has been added yet. 37 → 39 checks,
still 0.7 s.

**The decision the item asked for, resolved rather than deferred.** The worry
was a scratch file that is neither ignored nor meant to be committed. Checked
before widening: the repository currently has *zero* untracked-and-unignored
paths, and `.gitignore` already covers every category that produces them —
`/commit_msg.txt`, `build_*/`, `third_party/*`, `coverage/`, `gpsim.log`,
`*.gcda`/`*.gcno`/`*.gcov`, `*~`, `.claude/`. `scripts/make-release.sh` was the
one case worth confirming, and it stages into `mktemp -d` outside the tree, so
`make release` leaves nothing newly harvestable. The deciding argument is the
asymmetry: the tracked half is unchanged and identical on every machine, so CI
remains the floor and the new half can only ever catch *more*, *earlier*. A
local-only failure is a true positive about a file that is about to be
committed.

**Three things the specification did not say, all found in the doing.**

1. *A clean working directory cannot demonstrate the property.* There is no
   untracked file here to assert against — which is the same blindness that let
   the gap sit unnoticed. `check_harvest_scope()` therefore builds a throwaway
   fixture repository (staged with `git add`, never committed, so it needs no
   `user.email`; `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` neutralised so a
   developer's own `core.excludesFile` cannot change what is asserted) holding a
   tracked, an untracked and an ignored file. Both directions fail when broken,
   verified: dropping `--others` reports the untracked file missing, dropping
   `--exclude-standard` reports the ignored one extra.
2. *`PUBLISHED` became load-bearing.* A `release/v*/` directory is untracked
   while the release script is staging it. The path rule that excludes published
   artifacts used to be redundant for an unadded file and is now the only thing
   keeping a past release's goal names out of a check on the current tree. The
   fixture asserts it too.
3. *Whitespace splitting had to go.* The untracked half is the one that can hold
   a hand-typed name, and a space in it would have split into two nonexistent
   paths, both dropped by the existing `os.path.isfile` test — skipped
   **silently**, the exact defect class. Paths are read `-z`-delimited.

Verified end to end: an untracked file naming a nonexistent goal now fails the
run in which it is written, where before it passed and failed the run after.

**~~Upgrade residue from the `v0.9.8` renames.~~ DONE (2026-08-03), including
the selector rename that was held for the owner's call.** Filed as three trivial
loose ends. One of them was not trivial and not cosmetic: **it had already
broken `make release`.**

- **~~`build_pic/` is no longer ignored and is no longer cleaned.~~ DONE.** A
  retired-spelling line in `.gitignore` and an `rm -rf build_pic` in `clean`, on
  the same principle as `AVR_TEST_BINARIES_RETIRED` and the pre-`src/` KLEE
  paths: a worktree that predates a rename should not keep the old artifacts
  forever, and XC8's `.p1`/`.d`/`.sdb`/`.sym`/`.cmf` intermediates match none of
  `.gitignore`'s global patterns, so `git add -A` would have committed them.
- **~~The AVR soak binary kept the pre-rename vocabulary.~~ DONE, and the
  premise was wrong.** This was filed as cosmetic — `_t<n>` where the sibling
  simulation binaries had become `_attiny<n>`. It was a live severance in the
  release path. `scripts/make-release.sh` composed its own copy of the binary
  path, and `v0.9.8` updated THAT copy to `test/avr/test_soak_<v>_attiny<n>`
  while `AVR_SOAK_BIN` stayed `_t<n>`. Verified: `make -n
  test/avr/test_soak_cd4053_simple_attiny85` answered *"No rule to make
  target"*. `make release` would have died in step 3 — after `make test-long`
  and every qualification gate, an hour or more in — on "failed to build AVR
  soak attiny85_cd4053_simple".

  Fixed at the root rather than at the symptom: `AVR_SOAK_BIN` now spells
  `_attiny<n>`, and make-release.sh READS it (`make -s print-AVR_SOAK_BIN
  AVR_SOAK_VARIANT=... AVR_SOAK_CHIP=...`) instead of keeping a second copy. The
  image basenames beside it are restated on purpose — they are an independent
  opinion cross-checked against `RELEASE_IMAGES` — but this path was checked
  against nothing and only needed to be correct, which is the distinction the
  copy missed. The old `_t<n>` binaries join `AVR_TEST_BINARIES_RETIRED`.
- **~~`test/run_mutation_tests.sh` hand-composes an image path.~~ DONE.**
  Resolved once at startup from `print-PIC10F322_BUILD_DIR` +
  `print-PIC10F322_RELEASE_IMAGES`, selecting the image whose stage matches, so
  an output stage that no longer exists fails immediately and by name. The three
  restated defaults (`FW_BASE`, `PIC10F322_TAG`, `PIC10F322_BUILD_DIR`) are
  gone. The failure mode this removes is the bad one: a moved image makes
  `[ -f "$hex" ]` false, every PIC mutant returns the infrastructure-error
  status, and the lane degrades to a skip rather than a failure.

**~~`AVR_SOAK_CHIP` takes a bare `85`/`45`.~~ DONE**, on the owner's call, and
`AVR_SOAK_WITNESS_CHIP` with it — the two are one entry apart in
`VARIANT_SELECTORS`, and renaming one would have left the fragment spelling
looking deliberate rather than retired. Both now take a full part name
(`AVR_SOAK_CHIP=attiny45`).

The line the change draws is between the family's INTERNAL indexing and what a
request may name. `TINYX5` stays `85 45` because that is what indexes
`mmcu_<n>`/`part_<n>` and generates the `attiny<n>`/`attiny<n>-flash` goals; the
new `TINYX5_PARTS = $(foreach n,$(TINYX5),$(mmcu_$(n)))` is that same family as
parts, and it is what the two selectors validate against. Derived, not spelled
out, so a third sibling cannot enter one list and not the other. Downstream,
`$(mmcu_$(AVR_SOAK_CHIP))` collapses to `$(AVR_SOAK_CHIP)` in five places, and
`AVR_SOAK_BINARIES` is built from `TINYX5_PARTS` so the clean list is composed
from the same vocabulary as the target it must mirror.

Verified end to end rather than by inspection: the `attiny45`/`cd4053_with_mute`
combination builds and runs (`SOAK_RESULT ... status=pass`, MCU=attiny45,
against `bypass-attiny45-cd4053_with_mute.elf`), `test-soak-reset-witness` still
records its reset (16 checks), and all six `AVR_SOAK_BINARIES` paths plus the 15
release soak combination names are byte-for-byte what they were — the rename is
in the request vocabulary only, not in anything published.

The retired spelling now has a gate rather than a promise: the guard test
asserts `AVR_SOAK_CHIP=85` is rejected with *"is not supported; expected one of:
attiny85 attiny45"*, so the claim "the old command line gets a good error" fails
if it ever stops being true.

**Hardware-validation procedure.** The single largest residual verification gap
is structural: simavr cannot model the ATtiny13a watchdog system reset (only the
tinyx5 family), so the headline WDT-recovery guarantee on the *primary* part is
asserted by analogy, not direct simulation. Document a bench procedure: scope
PB1/PB2, artificially stop the ISR, confirm the device resets to BYPASS within
the WDT window; plus power-on glitch and BOD behaviour. Bridges to the HIL item
below, which is its automated realisation — keep this as the no-rig fallback.

**Inverted-copy (complemented) storage of the debounce context.** The main-loop
sanity gate detects *out-of-range* corruption of `ctx_` (`program_state >
RELEASE_DEBOUNCE_WAIT`, `effect_state > ENGAGED`, `debounce_counter >
RELEASE_THRESH`), but a single-event upset landing *in* range is invisible to it.
Concretely: (a) a `program_state` flip RELEASE_DEBOUNCE_WAIT→PRESS_DEBOUNCE_WAIT
while the lockout counter is still ≥ PRESSED_THRESH causes an **immediate
spurious toggle** — the worst case, audible; (b) an in-range `debounce_counter`
flip (e.g. 3→19, bit 4) can cross PRESSED_THRESH and likewise toggle without a
press; (c) an `effect_state` flip silently inverts the meaning of the next press
(it re-asserts the current physical state, so one press "does nothing"). The
classic hardening is complement storage: keep a second copy with all bits
inverted, update both at every write site, and have the per-tick sanity gate
verify `ctx_ == ~ctx_inv_` byte-wise, forcing the WDT reset (→ safe BYPASS) on
mismatch. Any single bit flip in either copy is then detected within one tick.

Design notes if picked up:
- Keep `bypass_pure.c` untouched — the shadow is shell-owned fault-detection
  mechanics, not algorithm; the pure core and its proofs stay as they are.
- AVR: the ISR writes `debounce_counter` every tick, so a naive 3-byte shadow
  check in main races the ISR (ISR fires between main reading a byte and its
  complement → false mismatch → spurious reset). Two clean options: shadow only
  the two main-loop-owned state bytes (no race by construction; still catches
  cases (a) and (c), and the counter is already range-checked and
  self-correcting); or a full shadow with pair-update in the ISR and a
  read-pair-retry in main (a mismatch is re-read once; only a *persistent*
  mismatch is corruption). Do NOT reach for cli/sei around the check — that would
  break the documented "no interrupts disabled in steady state" invariant.
- PIC10F322: single-threaded polled loop, so a full shadow is trivial — but watch
  the flash budget, which `make pic10f322` gates. RAM cost is +2–3 bytes against ample
  free space on both parts.
- PIC10F320: almost certainly does not fit. Check against its budget before
  promising cross-target parity, and record the omission if it cannot be done.
- Tests: extend both fault-injection suites with an **in-range** flip case
  (simavr t85: flip `effect_state` 0↔1, expect WDT reset; gpsim: same via the
  ctx_ cases, which today deliberately inject only out-of-range values precisely
  because in-range flips are undetectable), plus a mutation ("shadow update
  removed at one write site") proving the suite catches a maintenance slip.

Effort: ~3–6 h incl. tests; firmware edits are the user's. Impact: Medium —
closes the last undetectable single-bit-corruption class in the global state
under the project's cosmic-ray/EMI threat model. This is genuinely platinum:
range checks + WDT already exceed typical practice for this device class, and the
next rung above complement storage (triple modular redundancy) is out of
proportion for a guitar pedal.

**Broader compiler & toolchain portability.** Motivated less by any single MCU
than by two project goals: lowering the barrier for others to adopt/contribute,
and surfacing latent defects that a single compiler can mask
(register-allocation, volatile-ordering, ISR prologue/epilogue, UB that happens
to "work" under one optimizer). Two strands:

- *Modern pure-FSF AVR toolchain.* Build and document a canonical open toolchain
  from stable upstream sources (`binutils` ≥ 2.41, `gcc` ≥ 13 avr target,
  `avr-libc` ≥ 2.2.0 from github.com/avrdudes/avr-libc). avr-libc 2.2.0 has
  **native ATtiny202 support** — no atpack at all — so this both modernizes the
  AVR story and removes the one Microchip-hosted dependency the current ATtiny202
  build accepts. Heavier (a from-source build plus a documented procedure) but
  100% FSF and reproducible; keep it as the escape hatch if the packaged 7.3.0
  toolchain ever blocks a modern device.
- *Multi-compiler CI matrix.* Generalize the narrow cross-compiler item in
  Tier 2.5 into a matrix building the firmware under several open toolchains
  (multiple avr-gcc versions; clang's AVR target where viable) and running the
  full behavioural suite against each, asserting identical results. Each added
  compiler is both an adoption on-ramp and an independent bug-detector.

Effort: Medium (mostly CI plumbing plus a documented from-source build). Impact:
Medium-High — adoption plus a genuine reliability net.

**Hardware-in-the-loop (HIL) validation rig with register-level introspection.**
The simavr (AVR Classic), libgpsim (PIC), and yasimavr (AVR-XT) suites prove the
shells in simulation, but two gaps remain:

- (a) **No AVR-XT timing measured on a clock, only on a model.** yasimavr runs
  real ATtiny202 firmware, and (corrected 2026-08-02) it *does* model multi-cycle
  instruction timing — the earlier claim here that it charges one cycle per
  instruction was wrong, an artifact of measuring by single-stepping through the
  upstream `SimLoop.run()` defect described in `test/README.md`. Two gaps
  survive that correction. Until that fix reaches a pinned release, the harness
  cannot measure busy-delay width in-sim at all (absolute width comes from a
  disassembly oracle instead). And regardless of the fix, simulated time is
  *nominal*-clock time: the real part's internal oscillator tolerance over
  voltage and temperature only shows on a bench instrument.
- (b) **No existing test observes internal state on real silicon.** The suites
  assert I/O behaviour, not that the behaviour arises from the intended internal
  trajectory.

A HIL rig closes both: it re-hosts the behavioural suites on real parts and adds
register-level introspection, supporting a claim that the firmware matches its
formal model at the register level on real silicon — which most reference
firmware cannot make.

*On-chip debug reality (verified 2026-07-08).* All three families expose full
internal state (SRAM, registers, I/O) over an on-chip debug interface, but only
in **stop mode** — halt at a breakpoint, then read memory. None of these 8-bit
parts have data trace (continuous non-intrusive streaming while running; that is
a Cortex-M SWO/ITM feature), so internal state is snapshotted at breakpoints,
which perturbs timing. Per family:
- AVR Classic (t13a/x5): debugWIRE (1-wire, over RESET). Open-source host: Bloom
  (https://github.com/bloombloombloom/Bloom) → GDB remote-serial. Full
  SRAM/regs/IO when halted; HW breakpoints. Takes over RESET via the DWEN fuse.
- AVR-XT (ATtiny202): UPDI (1-wire, own pin). Open-source host: Bloom → GDB; its
  Insight view reads all data-space registers, GPIO, RAM/EEPROM and peripherals.
  The 8-pin budget is tight; MPLAB SNAP needs the R48 mod plus a UPDI pull-up.
- PIC10F32x: ICD via ICSP (2-wire). Weakest of the three — needs the bond-out
  debug header (AC244045) for full ICD, and there is no open-source host (MPLAB X
  only), ~1 HW breakpoint. (Ironic: best simulator, worst silicon debug.)

One cheap probe covers the whole fleet: MPLAB SNAP (~$20) speaks debugWIRE,
UPDI, and ICSP; Bloom drives it for the AVR sides and exposes a GDB server
scriptable from Python.

*Two-plane architecture.* Because the firmware is deterministic and tick-driven,
behaviour and internal state are validated over *identical* stimulus in two
passes:
1. Behavioural plane (real-time, non-intrusive): a dedicated driver MCU (an
   RP2040/Pico — PIO gives µs-precise edge generation plus timestamped capture)
   replays footswitch patterns and records LED/relay edges. This is the
   simulation behavioural suite re-hosted in hardware, and the home for the
   flaky/aging-switch models. The host orchestrates in Python and compares output
   timing against the golden model.
2. Introspection plane (stop-mode): SNAP + Bloom + GDB, scripted from Python —
   breakpoint at end-of-tick, dump the context, assert equality with the golden
   model's prediction for that tick. This is `model_step.h` lock-step lifted onto
   real silicon: same golden model, same comparison discipline, substrate changed
   from a simulator's memory to a chip's SRAM over a wire.

Run both planes over bit-identical stimulus; determinism guarantees plane 2
reproduces plane 1, so the internal-state proof and behavioural proof describe
the same run. State matching the model at every tick boundary is the "by design,
not by accident" evidence.

*Caveats to design in.*
- Stop-mode perturbs timing — it is a separate pass, never layered on the
  behavioural run.
- Software breakpoints rewrite flash (wear); prefer the limited HW breakpoints,
  or treat dev parts as consumable.
- Aging switches are partly analog (rising contact resistance, marginal or
  intermittent opens — exactly what the integrator exists to reject). Logic-level
  replay covers the debounce *logic*; testing the analog margin needs an analog
  stage (series MOSFET or digital pot) ahead of the input pin — a dedicated
  sub-tier.
- Prefer stop-mode introspection over a telemetry firmware build: telemetry is a
  different binary (observer effect) and the ATtiny202's 8 pins are nearly all
  spoken for. Stop-mode keeps the shipped binary un-instrumented.
- Determinism boundary: WDT/BOD async events and power-on/reset ramp timing are
  where the two passes could diverge; make the driver MCU the single source of
  truth for reset and input timing.

Effort: large — rough phasing: (1) behavioural plane on one AVR target with the
Pico driver plus Python orchestration (~1–2 days); (2) introspection plane via
Bloom/SNAP/GDB with the `model_step.h` comparator (~1–2 days); (3) aging/analog
switch sub-tier (~1 day plus hardware); (4) generalise across families (~1–2 days
each). Impact: High — enables a register-level "validated against the formal
model on real silicon" claim, and is the primary mitigation for the AVR-XT
cycle-timing gap. All test/rig plus docs work (no firmware-source changes), so it
is outside the firmware-edit-by-user constraint.

**Embedded provenance URL (firmware "comment" in flash).** Embed the project's
GitHub URL as a string constant in the firmware so that someone who reads the
image off an undocumented pedal's MCU and hex-dumps it can find the authoritative
source — the machine-code equivalent of a comment. Deferrable polish; not a bug.

Key constraints (so it actually works for the read-off-the-chip scenario):

- **Must land in a *programmed* (loadable) section**, i.e. end up in the `.hex`
  that gets flashed — not a metadata-only ELF section (`.comment`, `.note`),
  which exists only in the build-host `.elf` and is never written to silicon. On
  AVR that means `PROGMEM` (flash, never copied to RAM); on PIC/XC8 a
  program-memory `const`.
- **Must survive dead-stripping.** The AVR link line uses `-Wl,--gc-sections`, so
  an unreferenced string is collected. The clean modern fix
  `__attribute__((used, retain))` needs GCC 11+; the toolchain is **avr-gcc
  7.3.0**, where `retain` is unavailable and `used` alone does NOT survive
  link-time gc. Robust approach: force a zero-cost reference from `main`, e.g.
  ```c
  const char project_url[] PROGMEM = "github.com/matt-garman/mcu-bypass-firmware";
  /* in main(): keep --gc-sections from dropping the string (emits no real code) */
  __asm__ volatile("" :: "r" (project_url));
  ```
  For PIC, XC8 V3.10 places a `const char[]` in program memory; mark it
  `__attribute__((used))`.
- **Flash budget is the real constraint**, and it decides which parts can carry
  the string at all. On a 14-bit PIC core you cannot pack two characters into one
  word, so readable ASCII costs **one program word per character**. Gate the
  string behind a macro (e.g. `BYPASS_EMBED_URL`) so only parts with headroom
  carry it, and/or use a compact form (bare host/path, no scheme). Consider a
  recognizable leading marker so it is greppable in a dump.
- **PIC10F320 cannot carry a full URL** and likely never will: its three variants
  currently sit at 220/241/244 of 256 words, leaving 36/15/12 free against a
  ~48-character minimum for even a scheme-less repo URL. If the feature ships,
  scope it to the parts with real headroom rather than shortening the URL to
  something that rots. (A third-party shortener trades a space problem for a
  provenance-rot problem — the link dies if the service does.)
- **Verify it reached flash** (not just the ELF):
  ```
  avr-objcopy -O binary build_avr_classic/bypass-attiny85-tq2_l2_5v_relay.elf - | strings | grep github
  ```

Effort: ~1–2 h incl. the `BYPASS_EMBED_URL` Makefile wiring plus a
`strings`-based build check. Firmware source edit is the user's.

**`make pic10f320-program` convenience target.** <!-- name-contract: exempt (documents an absent goal) --> Added 2026-07-27. The PIC10F322
has `make pic10f322-program` (with `PIC10F322_PROG=pk2cmd|ipecmd`,
`PIC10F322_PROG_TOOL` and `PIC10F322_PROG_CMD` overrides); the PIC10F320 has no
equivalent, so `release/README.md` and the generated `MANIFEST.md` print the bare
`pk2cmd -PPIC10F320 -F<image> -M -Y -R` instead. The merge recorded this as a
deliberate omission rather than shipping it unverified
(`docs/pic10f320_merge_plan.md` §15.10): it is ~15 lines modelled on the 322
recipe, but it is hardware-programming surface that **cannot be tested without a
programmer and a part on the bench**, and a wrong programmer invocation aimed at
the wrong device is worse than an honest absence.

Design notes if picked up: mirror `pic10f322-program` exactly rather than inventing a
second idiom, add `PIC10F320_PROG*` variables under the part-prefix rule (the whole
point of the separate pair is that one chip can be re-pinned without moving the
other), and update the `make help` Hardware block, the PIC10F320 flashing section
in `release/README.md`, and the manifest's flashing command in the same change.
Verify against real silicon
before removing the "no convenience target yet" note — the note is currently
correct, and a target that has never driven a programmer is not an improvement
over a command the user can read.

Effort: ~1 h to write, plus bench time. Impact: Low — convenience only; the
documented `pk2cmd` invocation already works.

---

## Tier 4 — out of scope for firmware (name only)

A manufacturer adopting this reference design additionally needs: a professional
schematic (KiCad), a BOM with manufacturer part numbers and approved
substitutes, a hardware production test procedure, and an FMEA. These are outside
the firmware scope; naming them in the design doc as "out of scope / left to the
implementer" is itself evidence of thoroughness.

**Signal-integrity SPICE modeling of the footswitch input network.** Moved here
from Tier 2.5 (2026-07-26): this is hardware analysis, not firmware verification.
The design's EMI/RFI defense includes a hardware filter (TVS, ferrite, 1k series,
22nF to ground, 10k pull-up) with a time constant τ ≈ 18 µs. The firmware's 8 ms
integrator threshold is claimed to be ~80× the hardware filter corner, but that
ratio is an order-of-magnitude estimate, not a simulation. Before a PCB is
ordered, a SPICE transient analysis of the complete input network would verify
(a) that a 5 kV ESD pulse (IEC 61000-4-2 contact discharge) leaves the MCU pin
within absolute maximum ratings and the clamped pulse below Schmitt-trigger
VIL/VIH thresholds, and (b) that a GSM 900 MHz burst coupled onto a 10 cm
twisted pair leaves the filtered envelope above VIH for any burst shorter than
the integration window. Worth doing for whoever builds the board; it validates
the hardware assumptions the firmware relies on, but it is not firmware work and
should not gate firmware releases.

---

## Considered and declined

Recorded so these do not get re-proposed. None are refusals on grounds of
difficulty — each was judged to cost more than it returns *for this project*.

**PIC10F320 firmware on PIC10F322 hardware (low priority / academic
curiosity).** The two parts have the same software-visible core, pin map, RAM,
relevant SFR/peripheral layout and CONFIG-word layout; their material difference
for this firmware is 256 versus 512 implemented program words. A native
PIC10F320 image whose execution remains within its implemented address range is
therefore expected to run unchanged on a PIC10F322. The strongest experiment
would execute the exact native, hash-gated PIC10F320 HEX under both `p10f320` and
`p10f322`, compare traces through the shared target-I/O and lock-step harnesses,
then confirm it on real PIC10F322 hardware. Recompiling the source with
`-mcpu=10F322` would be a weaker compatibility proof because it creates a third
artifact whose startup, placement or bytes may differ.

This would not make all PIC10F322 qualification claims applicable. The
PIC10F320 firmware deliberately omits the PIC10F322 firmware's settled-`LATA`
integrity guard, so the three PIC10F322 output-latch fault injections must not be
expected to pass; native build, image-hash, program-geometry, source-coverage and
release-provenance gates also remain device/implementation specific. Most useful
mechanism reuse already exists: both parts share the CONFIG checker, gpsim
wrappers, libgpsim I/O/lock-step/fault cores, soak implementation and assembly
stack checker, with thin adapters preserving their different policies.

Declined as a maintained target or release gate: when PIC10F322 hardware is
available, its native modular firmware should be used because it compiles the
verified pure core directly and retains the stronger output-latch defence. A
cross-device lane would mostly validate an intentionally inferior firmware
choice while adding a third build/simulator profile and more fail-closed
orchestration. Reconsider only for a concrete universal-image, component-
substitution or manufacturing-SKU requirement; otherwise it remains an academic
differential-simulator exercise.

**Formal ISR/main interleaving model (TLA+ or SPIN).** Would formalize the
AVR ISR/main interleaving at the byte level, modeling each byte read/write as a
separate step, to prove all interleavings preserve the safety invariants — the
definitive treatment of the `ctx_` sharing that `test_model_check.c` covers only
at C-statement granularity. Declined as disproportionate: the existing
nondeterministic-scheduling proof plus lock-step co-simulation plus fault
injection already exceed what this device class receives, and the item's own
assessment was "overkill for a project of this size." Reconsider only if a
future shell shares a genuinely multi-byte object across an ISR boundary — the
PIC and AVR-XT shells deliberately do not.

**Property-based testing framework.** Would add rapidcheck-style generators with
biased distributions and automatic shrinking to supplement the hand-rolled
`xorshift32` fuzzing. Declined: the algorithm's state space is *already
exhaustively* proved by `test_model_check.c`'s BFS and by CBMC, so a smarter
random search cannot find a state those miss. It would add a dependency and a
maintenance surface to re-derive what is already proved by construction.

**ISR-timing-jitter stress test.** Would deliberately delay ISR servicing by
random cycle counts to confirm the debounce behaviour is insensitive to jitter.
Declined by its own reasoning: the firmware samples the pin once per
compare-match by design, so the test "would confirm an existing design property
rather than find a new bug." `test_clean_press_phase_jitter` already scatters
footswitch edges across the tick window, which covers the realistic case.

**Interrupt latency measurement in simavr.** Would measure compare-match-to-ISR
entry latency, ISR duration, and interrupt-disabled time per tick. Declined:
confirms an assumption (ISR overhead is negligible against a 1 ms tick at
1.2 MHz) that is not in doubt and whose violation would already surface as a
lock-step co-simulation divergence. The interrupt-free window item in Tier 2.5 is
retained because it guards an invariant a code change could actually break; this
one measures a constant.

**VCD waveform diff across output variants.** Would generate three VCDs from
identical stimulus and diff the LED edges to show variant-consistent behaviour.
Declined: the property is already asserted directly by the per-variant
behavioural tests, and the output is a documentation artifact rather than a gate.
`make attiny13a-trace` remains available for anyone who wants the waveform.

---

## Priority summary

| Item | Tier | Effort | Impact |
|---|---|---|---|
| Design doc: datasheet citations | 2 | 2 h | High — completeness/rigor |
| Re-pin yasimavr after the cycle-rewind fix | 2.5 | 1 h (+2 h optional) | Low — retires a documented simulator caveat |
| Return-stack oracle: extend to PIC10F322 | 2.5 | High | Low-Medium — second witness on a chip the assembly gate already bounds |
| Formal verification of output drivers | 2.5 | 3–4 h | Medium — driver correctness |
| Formal verification of blocking-delay safety | 2.5 | 1–2 h | Medium — makes the argument explicit |
| Golden-model vs `model_step` cross-validation | 2.5 | 1–2 h | Medium — fourth oracle path |
| Full-path symbolic execution (KLEE) | 2.5 | 2–4 h | High — whole-trajectory proof |
| KLEE in CI | 2.5 | 2 h | Medium — proves the path actually runs |
| Cross-compiler verification | 2.5 | 2 h | Medium — compiler-safety net |
| Compiler optimization sensitivity test | 2.5 | 1 h | Medium — quick win |
| Stack depth cross-verification | 2.5 | 2–3 h | Medium — third independent bound |
| `bypass_compile_checks.h` reach comment | 2.5 | 10–30 min | Low-Medium — corrects a centralisation claim |
| Clock drift fine-grained sweep | 2.5 | 1 h | Low — narrow but real edge case |
| WDT pet frequency measurement | 2.5 | 1–2 h | Medium — catches handshake bugs |
| Interrupt-free window measurement | 2.5 | 1 h | Medium — confirms runtime invariant |
| Multi-press boundary cases | 2.5 | 3–4 h | Medium — tick-boundary edge cases |
| Power-on-pressed simulation gap | 2.5 | 1–2 h | Low — simulator fidelity, not coverage |
| Power-supply ramp-up analysis | 2.5 | 2–3 h | Medium — real-world robustness |
| Hardware-validation procedure doc | 3 | 2–3 h | High — primary-part WDT gap |
| HIL rig: behavioural + register introspection | 3 | 5–8 d | High — silicon-level model validation |
| Inverted-copy (complemented) `ctx_` storage | 3 | 3–6 h | Medium — in-range SEU detection |
| Broader compiler & toolchain portability | 3 | Medium | Medium-High — adoption + reliability |
| Embedded provenance URL | 3 | 1–2 h | Low — provenance polish |
| `make pic10f320-program` target <!-- name-contract: exempt (absent goal) --> | 3 | 1 h + bench | Low — convenience; `pk2cmd` documented |
| Manufacturing artifacts (name as scope) | 4 | — | Completeness signal |
| Signal-integrity SPICE modeling | 4 | 2 h | High for the board, not firmware work |
