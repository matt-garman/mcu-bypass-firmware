# Release proportionality and soak attestation

## What this document is

A measurement of what the release path cost between `v0.9.9` and `v0.9.13`,
and what recovers the confidence-per-hour that `v0.9.9` had without giving up
any assurance about the firmware. Part 1 is a finding rather than a change --
the continuous validation it proposed already existed. Part 4 has landed;
Parts 2 and 3 are open. It is a companion to
[`docs/ci_parity.md`](ci_parity.md): that document closes the gap between what
runs locally and what runs remotely; this one addresses how much runs at all,
and when.

## What the record shows

Release machinery only -- `scripts/`, the release gates under `test/`, and
`release.yml` -- measured at the `v0.9.9` tag and at `v0.9.13`:

| | v0.9.9 | v0.9.13 | |
|---|---:|---:|---|
| Release machinery, lines | ~7,800 | ~21,800 | 2.8x |
| `make-release.sh` refusal points | 111 | 273 | 2.5x |
| -- of those, after the soak | 11 | 65 | 5.9x |
| `release-documentation.sh` | 186 lines, 0 refusals | 1,940 lines, 91 refusals | -- |
| -- `release_validate_claim_boundaries` alone | -- | 38 refusals | -- |
| Published images | 21 | 21 | 1.0x |
| Soak combinations | 18 | 18 | 1.0x |
| Staged files per release | 60 | 64 | 1.07x |
| `QUALIFICATION` schema | `format=1` | `format=7` | -- |

The product did not grow. The apparatus around it tripled. Of the 279 commits
in that window, 94 touched release machinery and 26 of those were `fix:`
commits repairing that machinery -- the clearest available fragility signal.

Part of the growth is a genuine new deliverable: the PIC12F675 flashing helper
became a published artifact, and a shipped tool legitimately needs the gating
that arrived with it. That accounts for perhaps a fifth of it, and is not the
source of the friction.

### Every failure was in the apparatus

| Release | Failed where | Cause |
|---|---|---|
| `v0.9.10` | Tag CI, after images reproduced | a workflow-scope `env:` leaked into the preflight baseline |
| `v0.9.12` (first attempt) | staging, after the soak | `toolchain.txt` was not staged |
| `v0.9.12` (second attempt) | Tag CI, after images reproduced | the image-continuity declaration becomes owed only once the release directory exists |

No firmware defect, and nothing a soak could have found. Two of the three were
discovered after a full-duration soak had already been paid for.

### Three of the last four releases soaked identical binaries

Comparing published images pairwise:

    v0.9.9  -> v0.9.10 :  2 identical, 19 changed
    v0.9.10 -> v0.9.11 : 21 identical,  0 changed
    v0.9.11 -> v0.9.12 : 21 identical,  0 changed
    v0.9.12 -> v0.9.13 : 21 identical,  0 changed

No soak driver changed across that span either. Three soaks re-ran the same
binaries under the same harness in the same simulators, and could not have
produced new information beyond another random sample.

Note what a source-tree hash would have concluded: `src/` *did* change over
those releases -- comments and compile-time guards that generate no code, which
is exactly what `v0.9.12`'s image-continuity declaration records. A key over
the source would have called these three releases different. The images are the
correct key, because the images are what the soak drives.

## The principle

**A release must only be able to fail on something that could not have been
known before it started.**

Everything below follows from applying that. Part 1 records where it was
already satisfied and where the first draft of this document was wrong about
that; Parts 2 to 4 are the places it was not.

## Part 1 - documentation is validated continuously, not on release day

`release-documentation.sh` was a renderer at `v0.9.9`: 186 lines, zero
refusals. It now carries 91 refusal points across six validators, and
`make-release.sh` calls five of them before it will start.

The first draft of this document proposed moving those calls to commit time.
That was wrong, and the correction matters more than the proposal: **they are
already there.** Every one of the six asserts against the live checked-in tree
inside `test/test_release_preflight.sh`, which is a member of `TEST_GATES` and
therefore runs in the default `make test`:

| validator | live-tree assertion |
|---|---|
| `release_validate_current_documentation` | through `development_state`, at the declared version |
| `release_validate_development_state` | direct |
| `release_validate_hardware_claims` | direct |
| `release_validate_claim_boundaries` | direct |
| `release_validate_pic12f675_finalization` | direct |
| `release_validate_pic12f675_flashing_helper` | direct |

`release_validate_development_state` exists for exactly this purpose, and says
so: the declaration is held "continuously rather than on release day", with the
version taken from `release/README.md` and the counts from the Makefile, so a
declaration cannot pass by agreeing with itself.

Two consequences follow.

**`release_reject_branch_only_documents` must stay on the release path.** It
refuses a release cut from an un-merged polish branch, where a branch-only
working document legitimately exists. Moving it to commit time would fail every
polish branch -- the exact hostility this document argues against. The preflight
suite already calls it on the live tree deliberately non-asserting, checking
only that the durable-document allowlist has not drifted.

**The `v0.9.13` friction was not missing coverage.** The tree is validated
against the version `release/README.md` declares. A release asked for a
different version before `scripts/release-prepare.sh` had moved that
declaration is a tree that has not been prepared yet, and the validator says
so, naming the repair. `make test` was green because the tree was consistent
for the version it actually claimed to be.

What was genuinely wrong here was smaller and is fixed: two live-tree
assertions passed hardcoded versions -- `v0.9.11`, two releases stale, and a
fictional `v1.2.3`. Both now read `release_current_contract_version`, which
`release_validate_development_state` also uses instead of its own copy of the
parse. Being exact about the value: the version is not load-bearing for either
of those two validators today, so this removes a literal that would rot rather
than closing a coverage gap.

The five phase-0 calls stay. They cost seconds, fail before anything is built,
and duplicating a check that `make test` already proves is cheap insurance
rather than a cost worth removing.

## Part 2 - rehearse staging before the soak

`make-release.sh` runs preconditions, builds, gates, soaks, then stages. Its
staging phase holds 65 refusal points, up from 11. Almost none of them read a
soak result: they validate manifest rendering, the flashing-command table,
resource rows, helper-artifact staging and the staged document set -- all
functions of the source tree and the built images, both of which stop changing
at the end of the build phase.

A rehearsal phase lands between the gates and the soak. It renders the complete
staging output into a throwaway directory with the soak-derived fields stubbed,
runs every check that does not read soak evidence, and discards the result. The
real staging phase then re-renders with true values; anything that diverges and
is not soak-derived is itself a defect worth failing on.

Cost: seconds. It reduces the post-soak refusal surface to the handful that are
genuinely bound to soak output -- the image-hash stability comparisons, the soak
table, the evidence index. The `v0.9.12` `toolchain.txt` death is removed by
construction rather than by remembering to stage a file.

This overlaps `docs/ci_parity.md` Part 4 and should land with it: that part
rehearses the artifact-commit *shape* before the soak, this one rehearses the
staged *content*. Same phase, same argument.

## Part 3 - attest the soak, and reuse it when the inputs are identical

The soak is the only part of the release whose cost is measured in days, and
the record above shows it has been re-run on unchanged inputs three times in a
row. A soak result should be a durable, signed statement about a set of inputs
rather than a fact about one release run.

### The attestation

    SOAK_ATTESTATION format=1
    inputs_sha256=<key>
    soak_duration_ms=86400000
    soak_liveness_interval_ms=60000
    combination_count=18
    completed_utc=<ISO-8601>
    source_commit=<informational only>

`inputs_sha256` is taken over a canonical manifest of everything that can
change what the soak observes:

1. the combination names;
2. the SHA-256 of the exact binary each combination drove -- the classic AVR and
   ATtiny202 ELFs, and each PIC HEX;
3. the soak driver sources, including the shared model headers they compile;
4. simulator and harness identity -- simavr, yasimavr, libgpsim, and the host
   compiler that built the soak binaries;
5. `soak_duration_ms` and `soak_liveness_interval_ms`.

Deliberately absent: the Git commit, `CHANGELOG.md`, `README.md`, anything
under `docs/`, the version string, and every documentation gate. A release that
changes only those produces an identical key.

The record is stored under `release/soak-attestations/<key>` with a detached
signature from the release signing key, alongside the digests of the retained
soak logs, so an attestation carries the same provenance guarantee as the
release artifacts themselves.

### Reuse

A `--reuse-soak` flag recomputes the key at the end of the build phase, looks
for a matching attestation, verifies its signature, and requires its attested
duration to be at least what the requested release mode demands. On a hit the
soak phase is skipped, the attested logs are folded into evidence, and
`QUALIFICATION` records `soak_provenance=attested` plus the key. On a miss the
soak runs and *writes* a new attestation.

It fails closed. Any change to an image, a driver, a simulator or a duration
changes the key, so an attestation can never be silently over-applied; there is
no invalidation step to remember.

`MANIFEST.md` states reuse in prose. A reader must be able to see that a given
release did not re-soak, and against which attestation it stands.

### The honest limit

A soak is a stochastic test. Re-running identical inputs is not strictly
zero-information: a rare race gets another sample. Reuse trades that additional
sample for the day it costs.

The policy that keeps this honest: reuse freely when the images are unchanged,
which is automatic since the key changes otherwise, and require a fresh
full-duration soak whenever any image changes. Whether a minor-version bump
should force a fresh soak regardless of image identity is a judgment for the
maintainer, not something this scheme should decide silently.

## Part 4 - scope the claim-boundary rules (done)

`release_validate_claim_boundaries` was 38 of the 91 documentation refusals and
held two unlike contracts in one function.

The six **fenced claim blocks** guard statements that must not silently weaken:
that no controlled hardware-qualification record exists for any part, that the
modular architecture overruns the PIC10F320 flash ceiling, what the PIC10F320
assurance package does not establish. A reworded sentence that drops a "not" is
a genuine integrity failure, the fence makes removal a visible diff, and the
term-group form introduced at `v0.9.13` already removed the brittleness of
pinning prose byte for byte. A release must not publish a claim stronger than
the evidence it ships, so these keep their release-time enforcement.

The six **current-fact rules** are regexes over `DESIGN_DOCUMENTATION.adoc` and
`TOOLCHAIN.adoc` rejecting restatements of release topology, unbound
measurements, and dates or commit SHAs in durable design prose. Each is a real
drift this project has had. None of them is a defect in a release.

They now live in `release_validate_current_fact_rules`, which runs on every
commit and which `make-release.sh` does not call. No rule was weakened: the
same six patterns, the same diagnostics, the same live-tree assertion. What was
added is the proof that the split holds -- a control asserting a current-fact
violation is *not* rejected by the contract the release path calls, and a
structural check that the release script never names the new function. A future
edit restoring that call for symmetry fails in `make test` rather than being
discovered by an operator who set a day aside.

## Sequencing

| # | Increment | Recovers |
|---|-----------|----------|
| 1 | current-fact rules split out of the release path (**done**) | a release that cannot be stopped by design prose |
| 2 | staging rehearsal before the soak | the post-soak failure class, at seconds of cost |
| 3 | soak attestation and reuse | the redundant soak; a lost release can re-use its own soak |

Increment 1 touched one file and removed no assurance. Increment 2 is
mechanical and pairs with `docs/ci_parity.md` Part 4. Increment 3 is the only
one carrying a real design decision, and the only one that changes what a
release attests.

## What this does not do

It does not reduce firmware assurance. The formal proofs, the exhaustive model
check, mutation testing, fault injection, the full soak matrix on changed
images, bit-reproducible builds and signed provenance are what make this
reference-grade, and every one of them stays exactly as it is. What changes is
that assurance about the *documentation* of the firmware stops being enforced
at the most expensive moment available, and that a soak is no longer repeated
against binaries it has already qualified.
