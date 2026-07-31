# shellcheck shell=bash
#
# Shared throwaway-repository builder. Sourced, never executed.
#
# WHY THIS IS SHARED
# ------------------
# Two harnesses copy the repository into a mktemp directory and run Make inside
# it:
#
#   test/run_mutation_tests.sh  -- one sandbox per mutant
#   test/test_pic_rebuild.sh    -- one sandbox for the PIC soak file rules
#
# They used to learn about a new file by different means: the walk below, versus
# a hand-enumerated list of prerequisites. test/pic/find_pin_exact.h -- made a
# prerequisite of BOTH chips' soak binaries and all three pic*-test-target legs
# -- broke each builder in turn, in two separate sessions.
#
# The mutation runner is where that hurts, because there a missing sandbox file
# does not surface as an error at all: the sandbox still builds, the baseline
# probe still runs, and the probe records a plain FAIL that the summary reports
# as a SKIP. The gate silently shrinks instead of breaking -- 18 mutants went
# unenforced while the run reported every mutant it did evaluate as killed, and
# the summary blamed an absent toolchain on a fully provisioned host. A green
# result that quietly measures less than it claims is the exact outcome this
# project's validation suite exists to prevent.
#
# One walk, one place to fix. Adding a substrate, nesting a harness, or giving a
# target a new prerequisite needs no edit here.
#
# TWO CONSTRAINTS THAT MUST SURVIVE ANY EDIT TO THIS FILE
# -------------------------------------------------------
# 1. The copy stays an ALLOWLIST, never a wholesale mirror. test/ also holds
#    BUILD PRODUCTS (test/avr/test_sim_*, test/formal/klee-out/, __pycache__),
#    and `cp -a` preserves mtimes -- a stale binary copied in newer than the
#    source beside it makes Make skip the rebuild, so a mutant is scored against
#    unmutated code. That is a silently WRONG answer, not a loud failure, which
#    is the one outcome a mutation harness must never produce. A wholesale
#    `cp -a test/` would buy convenience at exactly that price.
#
# 2. Nothing here may require a Git repository. These trees have no .git; a
#    `git ls-files` mode check in a Make recipe already failed closed in one
#    once (fixed by gating it on `git rev-parse --is-inside-work-tree`).

# scratch_tree_copy <repo-root> <destination>
#
# Populates <destination> with everything a sandbox Make invocation needs:
# the firmware sources, the Makefile, the whole scripts/ directory, and every
# source file under test/ at any depth. Idempotent -- callers re-run it to
# restore a sandbox they have deliberately damaged. Returns nonzero, quietly, on
# any failure; the caller owns the diagnostic.
scratch_tree_copy() {
    local root="$1" dst="$2" manifest src rel
    [ -n "$root" ] && [ -n "$dst" ] || return 1
    [ -f "$root/Makefile" ] || return 1

    mkdir -p "$dst/src" "$dst/test" || return 1
    # Every firmware source and header: the pure core, all four per-MCU shells,
    # all three output drivers, bypass_config.h. Copying the whole set keeps
    # this robust as variants are added or renamed.
    cp "$root"/src/*.c "$root"/src/*.h "$dst/src/" || return 1
    cp "$root/Makefile" "$dst/" || return 1
    # The Makefile's build/validate recipes invoke helper scripts under
    # scripts/ -- notably IHEX_VALIDATOR (scripts/validate-ihex.sh), which
    # `make pic` and the .hex rules REQUIRE and fail closed without. Mirror the
    # whole dir so a sandbox build behaves exactly like the real tree; -a
    # preserves the executable bit the validator-present check relies on.
    cp -a "$root/scripts" "$dst/" || return 1

    # Mirror every source file under test/, at ANY depth, filtered by extension
    # (see constraint 1 above for why the filter is not optional).
    #
    # Depth is what actually bit. The form this replaced copied test/*.h at the
    # root and then looped over test/<sub>/ taking only c/cc/sh/stc, which left
    # two whole classes invisible to every sandbox: headers in a subdirectory,
    # and anything three levels down (test/pic/fw_coverage/).
    #
    # One find(1) walk covers root and subdirectories uniformly. It also
    # subsumes the former test/pic10f320 wholesale special case (that subtree is
    # c/cc/h/py/sh/stc throughout) while, unlike `cp -a` of a directory,
    # declining to drag a stale __pycache__ in with it. -a still preserves the
    # executable bit the gpsim wrappers and check_fw_coverage.sh depend on.
    #
    # Non-source data (test/misra*.{json,txt}, README.md) stays out: no sandbox
    # build or kill target reads it. Add the extension here if that changes.
    manifest=$(mktemp "$dst/.scratch-tree-sources.XXXXXX") || return 1
    if ! find "$root/test" -type f \
        \( -name '*.c' -o -name '*.cc' -o -name '*.h' \
           -o -name '*.sh' -o -name '*.stc' -o -name '*.py' \) \
        -not -path '*/__pycache__/*' -not -path '*/klee-out/*' -print0 \
        > "$manifest"; then
        rm -f "$manifest"
        return 1
    fi
    while IFS= read -r -d '' src; do
        rel="${src#"$root"/}"
        if ! mkdir -p "$dst/${rel%/*}" || ! cp -a "$src" "$dst/$rel"; then
            rm -f "$manifest"
            return 1
        fi
    done < "$manifest"
    rm -f "$manifest" || return 1
}
