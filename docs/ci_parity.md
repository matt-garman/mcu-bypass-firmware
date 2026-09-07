# Remote-CI parity and the publishable artifact commit

## The two failures this closes

`v0.9.12` was qualified locally over a 24-hour soak, staged, committed, signed,
tagged and pushed. Tag CI reproduced all 21 images bit for bit and then failed
re-running `make test-long`, on a gate that had been green locally an hour
earlier. The release was a total loss: the tag is spent, the qualification is
bound to a source commit that must now change, and the soak has to run again.

Two independent defects produced that, and they need different fixes.

**Tree shape.** `make test-long` is mirrored locally, ran locally, and passed.
It passed because before the artifact commit `release/v0.9.12/` does not exist:
the newest release on disk is the previous one, its image-continuity
declaration is present, and every gate is green. The failing condition exists
only in a tree that contains the new release directory and its registry append
-- which is the tag's tree, and nothing local ever builds it. The earlier
`v0.9.12` death (an unstaged `toolchain.txt`) was the same class. Running the
same goals locally cannot catch either; the goals are not what differ.

**Inventory.** `scripts/ci-local.sh` reconstructs `ci.yml`'s jobs from a prose
comment header, `release.yml` keeps its own list of gate re-runs, and
`test/README.md` a third. Nothing machine-checks that the local path covers the
remote one. "A clean pass here means the CI matrix will be green" is, today, an
assertion in a comment.

## Part 1 - parity by construction: `ci-<job>` goals

Rather than test that two hand-maintained inventories agree, remove one of
them. Every gate a workflow runs becomes a named Make goal; the workflow step
invokes that goal and nothing else; the local mirror invokes the same goals.
Parity stops being a claim and becomes the shape of the file.

The Makefile declares the set. As of the first increment it holds the five
gate jobs `ci.yml` runs:

    CI_GOALS = ci-verify ci-stress ci-pic ci-mutation ci-attiny202

The build-matrix job's goals and the release-side goals join it as those jobs
are converted.

Each goal owns *gate composition and fixed policy flags* -- `STRICT_TOOLS=1`,
`MUTATION_ALLOW_SKIP=0`, `PIC12F675_FLASH_IMAGES=build`, the soak's PASS-count
assertion that is currently loose shell in the workflow step. Each goal does
NOT own the host paths or the independent CI pins: `PIC_CC`, `PIC_DFP`,
`PIC10F320_CC`, `PIC10F320_DFP`, `XT_STATIC_RAM_LIMIT`, `XT_STACK_MAX_FRAME`,
`PIC12F675_DATA_LIMIT` stay command-line variables supplied by the workflow,
because their whole purpose is to be pinned independently of Make's production
defaults so that a mismatch fails the run instead of agreeing with itself.

One change of substance goes with the move: a `ci-*` goal must FAIL when a pin
it declares is unset, rather than falling back to the Makefile default. Today a
workflow that dropped `XT_STATIC_RAM_LIMIT` would silently lose the
independence the two-value scheme exists to provide.

Non-emptiness is not the test, and assuming it was is the first thing that went
wrong in implementation: every one of these pins has a default in the Makefile,
so a goal checking only for a value passes on the default -- which is precisely
the failure the two-value scheme exists to catch. `$(origin VAR)` is what
distinguishes a caller's pin from this file's own answer, and the check requires
`command line` specifically.

`scripts/ci-local.sh` then executes `$(CI_LOCAL_SEQUENCE)` read from the
Makefile instead of a comment header, and its CI-JOB MAPPING block shrinks to
an explanation of the ordering rather than a second copy of the inventory.
Whatever reads that inventory must pass `--no-print-directory`: a sub-make's
`MAKEFLAGS` carries a `w`, which overrides `-s` and corrupts the output of a
variable query. `scripts/verify-release-artifact-commit.sh` already reads
`RELEASE_ARTIFACT_GATES` that way.

**The pattern, established on `verify` and `stress`.** Converting a job is
three edits that must land together:

1. the workflow step's `run:` invokes that job's goal from `CI_GOALS` and
   nothing else, carrying only the pins the caller supplies;
2. `test_workflow_syntax.sh`'s detection for that job matches the goal instead
   of the literal command -- it locates each job's step by command and anchors
   its ordering assertions to whatever it finds;
3. every policy assertion the workflow step used to satisfy moves to reading the
   goal's recipe, through `ci_goal_recipe()`. Dropping them instead would retire
   real checks silently, which is the failure mode this whole document is about.

`scripts/ci-local.sh` needs a fourth edit only where it mirrors a converted job
directly. Its non-PR path deliberately folds `verify`, `stress` and the mutation
gate into one `make test-long`, which is a local optimisation rather than drift;
its PR path mirrors `verify` one-for-one and now invokes `ci-verify`. That moves
what `test_ci_local_routing.sh` observes from the inner goal to the wrapper, so
the inner command is asserted against the recipe instead.

## Part 2 - the parity gate: `test-ci-parity`

Extends `test/test_workflow_syntax.sh`, which already parses both workflows
with a duplicate-key-safe loader and already knows that `ci-local.sh` mirrors
`ci.yml`'s jobs. It asserts, fail-closed:

1. Every `run:` step that invokes `make` invokes exactly one goal, and that
   goal is in `$(CI_GOALS)`. Matrix jobs are expanded from `strategy.matrix`
   before matching.
2. No `run:` step invokes a program under `test/` directly, and no step invokes
   a project gate outside a `ci-*` goal. Environment steps -- `apt-get`, the
   toolchain installers under `scripts/`, cache and checkout actions -- carry no
   Make or test invocation at all, so they need no allowlist to be distinguished.
3. Every variable name passed on a `ci-*` invocation is in that goal's declared
   allowlist, and every pin the goal requires is passed.
4. Every goal in `$(CI_GOALS)` appears in some workflow step or is declared
   local-only (`ci-preflight`).
5. `ci-local.sh` runs every `ci-*` goal `ci.yml` uses; the release recipe runs
   every one `release.yml` uses.

Tool policy follows the existing file: PyYAML absent skips cleanly, and fails
under `STRICT_TOOLS=1`, which `ci-local.sh` sets.

Grepping the workflows for the word "make" is not sufficient and must not be
the implementation: several hits in `release.yml` are English sentences inside
comments -- "make git", "make is", "make missing" -- not commands. The steps
have to come from the parsed YAML. (Writing those three as inline code here
would make this document itself name three goals the Makefile does not have,
which `test-makefile-name-contract` reports; the scanner and the parity test
are looking for the same class of mistake from opposite ends.)

## Part 3 - the artifact commit must prove itself before the tag

`make-release.sh` deliberately mutates nothing in Git: it stages
`release/<version>/`, writes `commit_msg.txt`, and prints a recipe the operator
runs by hand. The artifact commit therefore does not exist while the script is
running, and the script cannot test it. That is the gap.

A new step lands between commit and tag:

      # 4. commit the release and its exact append-only registration
      git add release/<version> test/published_release_digests.txt
      git commit -F release/<version>/commit_msg.txt

      # 4b. prove the artifact commit is publishable (REQUIRED)
      ./scripts/verify-release-artifact-commit.sh <version>

      # 5-6. printed by 4b, on success only

`verify-release-artifact-commit.sh` runs against `HEAD`, which is now exactly
the tree the tag will carry:

- the tree must BE that commit -- no tracked file may differ from `HEAD`, and a
  tag of this version must not already exist, since a spent tag is not amended;
- the four files a release signs for itself must be present, non-empty, regular
  files, and the manifest must not carry the dry-run banner;
- `scripts/verify-release-signature.sh` and `scripts/verify-release-history.sh`
  -- the two checks tag CI makes before it builds anything, the second proving
  `HEAD` is a single-parent child of the qualified source changing only
  `release/<version>/` plus the one canonical registry append;
- `RELEASE_ARTIFACT_GATES` from the `Makefile`, under `STRICT_TOOLS=1` and the
  independent pins read out of `release.yml` rather than restated here.

Why that gate list and not the whole suite: the history check above is what
bounds it. An artifact commit may change only the release directory and the
registry append, so a gate that reads neither cannot decide differently there
than it did during qualification. Re-running the rest would cost hours to
re-confirm results its own diff proves cannot have changed. The membership rule
is written beside the list, because a gate added later that reads a published
release re-opens the window if it is not added there too. After Part 1 lands,
this list becomes the body of the release-side `ci-` goal, and the local run
and the public attestation are the same composition by construction.

**Hard refusal.** The tag and push commands are not printed by
`make-release.sh` at all. They are printed by this script, on success only, and
it exits non-zero otherwise. An operator who never runs it never receives a tag
command to paste. The script mutates nothing, consistent with the rest of the
release path.

The reason this is worth its wall time after a 24-hour soak: it is the only
local run whose tree is the tree that gets published.

## Part 4 - rehearse the shape, not just the tools

`--dry-run` today proves the pipeline runs and produces a staging directory. It
does not produce the shape that fails: no artifact commit, no registry append,
no `HEAD` for the gates to read. Extend it to stage into a scratch clone,
create the artifact commit there, and run Part 3's verifier against it.

The staged *shape* does not depend on soak duration; only the evidence content
does. So a dry run costs about an hour and can be done BEFORE starting the real
soak. Both `v0.9.12` failures would have surfaced there, with nothing spent.

## Sequencing

**Parts 1 and 2 cannot land separately.** The sequencing below proposed
converting one workflow job at a time, with the parity gate arriving afterwards.
That is not possible: `test/test_workflow_syntax.sh` already locates each job's
strict-suite step by matching its literal command -- `make test STRICT_TOOLS=1`,
`make stress STRICT_TOOLS=1` -- and anchors seven ordering assertions per job to
the step it found. Pointing two steps at `ci-verify` and `ci-stress` produced 16
failures from those two substitutions alone, none of them a defect: the gate was
correctly reporting that the shape it knows had changed.

So the unit of work is a job's goal *and* the gate's detection for that job,
together. The goals can be defined ahead of the wiring -- they are inert until a
workflow invokes one -- but no workflow step moves until the gate learns the new
shape.

| # | Increment | Catches |
|---|-----------|---------|
| 1 | `CI_GOALS` + `ci-*` goals as exact wrappers of today's commands (**done**) | nothing yet -- pure restructure |
| 1b | each job's step pointed at its goal, with `test_workflow_syntax.sh`'s detection for that job moved in the same change (`verify`, `stress` **done**; `pic`, `mutation`, `attiny202`, `build-matrix` remain) | nothing yet -- pure restructure |
| 2 | `ci-local.sh` reads the sequence from Make | drift between the local mirror and its own header |
| 3 | `test-ci-parity` in `make test` | a workflow step with no local counterpart; a dropped pin |
| 4 | `verify-release-artifact-commit.sh` + recipe hard refusal | every post-staging failure, at zero cost |
| 5 | `--dry-run` builds the artifact-commit shape | the same, before the soak rather than after |

Increment 4 is the highest value per line and does not depend on 1-3. Do it
first if the restructure has to wait.

## What this does not do

It does not emulate the Actions runner. A green local run still cannot prove
that a hosted runner has the tools, that a cache restored, or that the network
behaved. It closes the class where the two run different work, or run the same
work against different trees -- which is the class that has cost this project
two releases.
