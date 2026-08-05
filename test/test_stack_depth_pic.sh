#!/usr/bin/env bash
set -euo pipefail

# Host-only regression for test/check_stack_depth_pic.sh, the PIC hardware
# return-stack gate.
#
# The gate reads XC8-generated assembly, so a regression that needed XC8 could
# only run where the compiler is installed -- and the whole point of a gate that
# bounds a silent, undetectable-at-runtime failure is that it is never the thing
# that quietly stops running. Every case below is a synthetic .s fixture in the
# format XC8 emits, so this runs inside `make test` with no toolchain at all.
#
# It asserts the gate ACCEPTS the shapes a real program takes -- in budget, at
# the exact boundary, and with an ISR (whose tree sums with the main one and
# whose duplicated helpers XC8 names without a leading underscore) -- and that
# it REJECTS each way the analysis can be wrong: over budget, recursion, an
# overflowing build (XC8 zeroes its callstack directives), a corroboration
# mismatch between the two oracles, an unresolvable or indirect call, a missing
# entry point, and a device pack with no declared depth. A gate that has never
# rejected anything is an assumption, not a check.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE="$ROOT/check_stack_depth_pic.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-stack-depth-pic.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

[ -x "$GATE" ] || { printf 'FAIL: gate not executable: %s\n' "$GATE" >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- fixture builders --------------------------------------------------------
# emit_fn <file> <name> <called-by> <callee...>   -- one XC8-shaped function block
emit_fn() {
	local f=$1 name=$2 by=$3; shift 3
	{
		printf ';; *************** function %s *****************\n' "$name"
		printf ';; This function is called by:\n'
		printf ';;\t\t%s\n' "$by"
		printf ';; This function calls:\n'
		if [ "$#" -eq 0 ]; then printf ';;\t\tNothing\n'; else printf ';;\t\t%s\n' "$@"; fi
		printf '\n'
		printf '__ptext_%s:\t;psect for function %s\n' "${name#_}" "$name"
		local c
		for c in "$@"; do printf '\tfcall\t%s\n' "$c"; done
		printf '\treturn\n\n'
	} >> "$f"
}
# emit_callstack <file> <value>  -- one directive; the gate takes the minimum
emit_callstack() { printf '\tcallstack %s\n' "$2" >> "$1"; }

run_gate() { "$GATE" "$@" 2>&1; }

expect_pass() {
	local desc=$1 fixture=$2 depth=$3 reserve=$4 want_peak=$5 out
	if ! out=$(run_gate "$fixture" "$depth" "$reserve" "$desc"); then
		fail "$desc: gate rejected a valid program: $out"
	fi
	[[ "$out" == *"STACK-DEPTH PASS"* ]] || fail "$desc: no PASS marker: $out"
	[[ "$out" == *"measured peak : $want_peak level(s)"* ]] \
		|| fail "$desc: expected peak $want_peak, got: $(printf '%s' "$out" | grep 'measured peak')"
	checks=$((checks + 1))
}

expect_fail() {
	local desc=$1 fixture=$2 depth=$3 reserve=$4 marker=$5 out
	if out=$(run_gate "$fixture" "$depth" "$reserve" "$desc"); then
		fail "$desc: gate ACCEPTED what it must reject: $out"
	fi
	[[ "$out" == *"$marker"* ]] \
		|| fail "$desc: rejected for the wrong reason (wanted '$marker'): $out"
	[[ "$out" != *"STACK-DEPTH PASS"* ]] || fail "$desc: printed a PASS marker while failing"
	checks=$((checks + 1))
}

# --- 1. a well-formed, in-budget program is accepted -------------------------
# _main -> _a -> _b  == 2 pushes; 8-level stack, so 6 remain.
f="$work/ok.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"                    _b
emit_fn "$f" _b    "_a"
emit_callstack "$f" 6
expect_pass "in-budget" "$f" 8 2 2

# --- 2. over budget fails on the reserve, not just on the raw depth ----------
# A 7-deep chain fits the 8-level stack outright, and must STILL fail with a
# reserve of 2 -- the reserve is the point, since the debugger takes a level.
f="$work/over.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _f1
for i in 1 2 3 4 5 6; do emit_fn "$f" "_f$i" "_f$((i-1))" "_f$((i+1))"; done
emit_fn "$f" _f7 "_f6"
emit_callstack "$f" 1
expect_fail "over-budget" "$f" 8 2 "exceeds the 8-level hardware stack"

# --- 3. the boundary is inclusive -------------------------------------------
# 6 deep + 2 reserve == 8 exactly: must PASS, so the gate is not off by one.
f="$work/edge.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _f1
for i in 1 2 3 4 5; do emit_fn "$f" "_f$i" "_f$((i-1))" "_f$((i+1))"; done
emit_fn "$f" _f6 "_f5"
emit_callstack "$f" 2
expect_pass "boundary-exact" "$f" 8 2 6

# --- 4. recursion is fatal on a non-reentrant core ---------------------------
f="$work/rec.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"                    _b
emit_fn "$f" _b    "_a"                       _a
emit_callstack "$f" 4
expect_fail "recursion" "$f" 8 2 "recursion on a non-reentrant core"

# --- 5. an overflowing build zeroes every callstack directive ----------------
# This is what real XC8 emits alongside warning 1393; it must not read as
# "no corroboration available, carry on".
f="$work/zeroed.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"
emit_callstack "$f" 0
emit_callstack "$f" 0
expect_fail "xc8-zeroed-callstack" "$f" 8 2 "could not fit the call graph"

# --- 6. the two oracles disagreeing is a failure, never a silent preference --
# Computed peak is 2; callstack claims 8-6=2 when correct, so 5 means 3.
f="$work/drift.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"                    _b
emit_fn "$f" _b    "_a"
emit_callstack "$f" 5
expect_fail "oracle-drift" "$f" 8 2 "disagrees with XC8 callstack"

# --- 7. a call to a symbol with no annotation block is unresolvable ----------
f="$work/unres.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"
printf '\tfcall\t_nowhere\n' >> "$f"
emit_callstack "$f" 6
expect_fail "unannotated-callee" "$f" 8 2 "call to unannotated symbol"

# --- 8. an indirect call makes the static graph incomplete ------------------
f="$work/indirect.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"
printf '\tcallw\n' >> "$f"
emit_callstack "$f" 6
expect_fail "indirect-call" "$f" 8 2 "indirect call"

# --- 9. no annotations at all must not read as "depth 0" --------------------
f="$work/bare.s"; : > "$f"
printf '\tmovlw\t1\n\treturn\n' >> "$f"
expect_fail "no-annotations" "$f" 8 2 "no XC8 function annotations"

# --- 10. exactly one reset entry point ---------------------------------------
f="$work/tworoot.s"; : > "$f"
emit_fn "$f" _main  "Startup code after reset" _a
emit_fn "$f" _other "Startup code after reset"
emit_fn "$f" _a     "_main"
emit_callstack "$f" 7
expect_fail "two-reset-entries" "$f" 8 2 "expected exactly 1 reset entry point"

# --- 11. an ISR tree costs its own push and SUMS with the main tree ----------
# main -> _a (1 push) and an ISR 1 deep. An interrupt can land at the deepest
# point of the main tree, so the budget is 1 + (1 + 1) = 3, not max(1, 2).
f="$work/isr.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"
emit_fn "$f" _isr  "Interrupt level 1"        _ihelp
emit_fn "$f" _ihelp "_isr"
emit_callstack "$f" 5
expect_pass "isr-tree-sums" "$f" 8 2 3

# --- 12. XC8's interrupt-context duplicate is a real call edge ---------------
# A non-reentrant helper reachable from BOTH main and an ISR is duplicated by
# XC8 (advisory 1510), and the copy is named i1_<name> -- with no leading
# underscore, unlike every other C symbol it emits. Case 11 above cannot catch a
# parser that requires that underscore, because its synthetic helper is spelled
# _ihelp; this fixture uses the name the compiler actually produces.
#
# Dropping the _isr -> i1_help edge does not under-count the depth: it leaves
# i1_help with no callers, and the root/entry cross-check rejects that. The
# symptom is a confusing "is never called but XC8 does not list it as an entry
# point" pointing at the firmware, when the fault is in this parser.
#
# main: _main -> _a -> _help = 2 pushes. ISR: _isr -> i1_help = 1, +1 for the
# push hardware makes on entry = 2. Trees sum: 4.
f="$work/isrdup.s"; : > "$f"
emit_fn "$f" _main   "Startup code after reset" _a
emit_fn "$f" _a      "_main"                    _help
emit_fn "$f" _help   "_a"
emit_fn "$f" _isr    "Interrupt level 1"        i1_help
emit_fn "$f" i1_help "_isr"
emit_callstack "$f" 4
expect_pass "xc8-i1-duplicate" "$f" 8 2 4

# --- 13. unusable inputs ------------------------------------------------------
: > "$work/empty.s"
expect_fail "empty-file"    "$work/empty.s"   8 2 "generated assembly is empty"
expect_fail "missing-file"  "$work/absent.s"  8 2 "generated assembly not found"

# --- 14. a device pack that declares no depth must not fall back to a guess ---
printf 'ARCH=PIC14\n' > "$work/nodepth.ini"
expect_fail "ini-without-stackdepth" "$work/ok.s" "$work/nodepth.ini" 2 "no STACKDEPTH="
printf 'ARCH=PIC14\nSTACKDEPTH=8\n' > "$work/good.ini"
expect_pass "depth-read-from-ini" "$work/ok.s" "$work/good.ini" 2 2

printf 'PIC stack-depth gate validation: %d checks, 0 failures\n' "$checks"
