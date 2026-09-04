#!/usr/bin/env bash
set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
# This only reports; `set -e` still does the exiting, so control flow is unchanged.
# The `case $-` guard is required, not defensive: bash runs an ERR trap even
# inside a deliberate `set +e` block, and several suites use one around a
# command whose non-zero status IS the expected result (`make -q` returns 1).
# Without the guard those print a spurious FAIL that lands in retained
# release evidence, because test-long.summary.txt is built by grepping ^FAIL.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

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
# mismatch between the two oracles, unresolvable direct calls in every accepted
# lexical form, indirect calls, missing/malformed corroboration, invalid function
# psect ownership, a missing entry point, and a device pack with no declared
# depth. A gate that has never rejected anything is an assumption, not a check.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE="$ROOT/check_stack_depth_pic.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-stack-depth-pic.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

[ -x "$GATE" ] || { printf 'FAIL: gate not executable: %s\n' "$GATE" >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- fixture builders --------------------------------------------------------
# The psect scaffolding around each body is not decoration, and getting it wrong
# here is what let a real regression ship. XC8 declares the function's psect,
# emits the `;psect for function` marker, and then RE-SELECTS that same psect
# before a single instruction of the body:
#
#     psect  text1,local,class=CODE,delta=2,merge=1,group=0
#     global __ptext1
#     __ptext1:  ;psect for function _init
#     psect  text1               <-- re-selection; still inside _init
#     _init:
#             fcall  _hw_wdt_pet
#
# It re-selects again after every inline-asm escape. A gate that reads any psect
# directive as leaving the function puts every body outside any function psect
# and loses every call edge in every real image, so fixtures that omit the
# re-selection cannot detect that. Emit what the compiler emits.
#
# emit_fn_body <file> <name> <called-by> <calls-annotation...> -- header + psect
# scaffolding, up to and including the body label. Instructions follow.
emit_fn_body() {
	local f=$1 name=$2 by=$3; shift 3
	local ps="text_${name#_}"
	{
		printf ';; *************** function %s *****************\n' "$name"
		printf ';; This function is called by:\n'
		printf ';;\t\t%s\n' "$by"
		printf ';; This function calls:\n'
		if [ "$#" -eq 0 ]; then printf ';;\t\tNothing\n'; else printf ';;\t\t%s\n' "$@"; fi
		printf '\n'
		printf 'psect\t%s,local,class=CODE,delta=2,merge=1,group=0\n' "$ps"
		printf 'global __p%s\n' "$ps"
		printf '__p%s:\t;psect for function %s\n' "$ps" "$name"
		printf 'psect\t%s\n' "$ps"
		printf '%s:\t\n' "$name"
	} >> "$f"
}
# emit_fn <file> <name> <called-by> <callee...>   -- one XC8-shaped function block
emit_fn() {
	local f=$1 name=$2 by=$3; shift 3
	emit_fn_body "$f" "$name" "$by" "$@"
	{
		local c
		for c in "$@"; do printf '\tfcall\t%s\n' "$c"; done
		printf '\treturn\n\n'
	} >> "$f"
}
# emit_fn_op <file> <name> <called-by> <opcode> <callee>
emit_fn_op() {
	local f=$1 name=$2 by=$3 opcode=$4 callee=$5
	emit_fn_body "$f" "$name" "$by" "$callee"
	{
		printf '\t%s\t%s\n' "$opcode" "$callee"
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

# --- 7a. target spelling must never decide whether a direct call exists -------
# Exercise each direct opcode separately so recognizing one cannot hide a hole
# in another. None of these unprefixed targets has an annotation.
for opcode in call fcall lcall pcall; do
	f="$work/unprefixed-$opcode.s"; : > "$f"
	emit_fn_op "$f" _main "Startup code after reset" "$opcode" x_helper
	emit_callstack "$f" 7
	expect_fail "unprefixed-$opcode" "$f" 8 2 \
		"call to unannotated symbol x_helper from _main"
done

# Lexical layout and comments cannot decide whether the same direct call exists.
f="$work/psect-in-comment.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf '\tfcall\tx_helper ;psect is comment text, not a transition\n' >> "$f"
emit_callstack "$f" 7
expect_fail "psect-text-in-call-comment" "$f" 8 2 \
	"call to unannotated symbol x_helper from _main"

f="$work/inline-label-call.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf 'local_label: FCALL x_helper\n' >> "$f"
emit_callstack "$f" 7
expect_fail "inline-label-uppercase-call" "$f" 8 2 \
	"call to unannotated symbol x_helper from _main"

f="$work/column-zero-call.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf 'LCALL x_helper\n' >> "$f"
emit_callstack "$f" 7
expect_fail "column-zero-uppercase-call" "$f" 8 2 \
	"call to unannotated symbol x_helper from _main"

# Unprefixed symbols are valid when XC8 provides annotations for them. This
# chain uses all four direct opcodes and must measure every edge.
f="$work/unprefixed-known.s"; : > "$f"
emit_fn_op "$f" _main "Startup code after reset" call x_a
emit_fn_op "$f" x_a   "_main"                   fcall x_b
emit_fn_op "$f" x_b   "x_a"                     lcall x_c
emit_fn_op "$f" x_c   "x_b"                     pcall x_d
emit_fn    "$f" x_d   "x_c"
emit_callstack "$f" 4
expect_pass "unprefixed-known-chain" "$f" 8 2 4

# Startup/runtime helpers outside function psects are not C call-graph edges.
# Cover both the preamble and a non-function psect after a function body so a
# stale `cur` cannot attribute runtime plumbing to the last C function.
f="$work/runtime-preamble.s"; : > "$f"
printf '\tfcall\tclear_ram0 ; XC8 startup helper\n' >> "$f"
emit_fn "$f" _main "Startup code after reset"
emit_callstack "$f" 8
expect_pass "runtime-call-before-functions" "$f" 8 2 0

f="$work/runtime-psect.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf '\tpsect\truntime,class=CODE\n\tfcall\tclear_ram0 ; XC8 runtime helper\n' >> "$f"
emit_callstack "$f" 8
expect_pass "runtime-call-after-psect-transition" "$f" 8 2 0

# --- 7b. re-selecting a body's OWN psect is not a transition out of it --------
# XC8 restores the psect after every inline-asm escape, mid-body. This is the
# shape that broke every real image once the gate started reading psect
# directives: the restore ended the function, and the call after it was reported
# as occurring outside any function psect.
f="$work/psect-reselect.s"; : > "$f"
emit_fn_body "$f" _main "Startup code after reset" _a
printf '%s\n' \
	'# 207 "src/bypass_mcu_pic10f322.c"' \
	'clrwdt ;# ' \
	'psect	text_main' \
	'	fcall	_a' \
	'	return' >> "$f"
emit_fn "$f" _a "_main"
emit_callstack "$f" 7
expect_pass "psect-reselect-after-inline-asm" "$f" 8 2 1

# The permission is exact: a DIFFERENT psect mid-body still ends the body, so
# the fail-closed direction the re-selection rule relaxes is still covered.
f="$work/psect-switch.s"; : > "$f"
emit_fn_body "$f" _main "Startup code after reset" _a
printf '%s\n' \
	'psect	somewhere_else,class=CODE,delta=2' \
	'	fcall	_a' \
	'	return' >> "$f"
emit_fn "$f" _a "_main"
emit_callstack "$f" 7
expect_fail "psect-switch-inside-body" "$f" 8 2 \
	"call to annotated function _a occurs outside any function psect"

# A marker with no psect declaration of its own must not inherit the previous
# function's binding -- otherwise that psect's name would re-open a body it
# does not own.
f="$work/psect-inherited.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
printf '%s\n' \
	';; *************** function _a *****************' \
	';; This function is called by:' \
	';;	_main' \
	';; This function calls:' \
	';;	_b' \
	'__ptext_a:	;psect for function _a' \
	'psect	text_main' \
	'	fcall	_b' \
	'	return' >> "$f"
emit_fn "$f" _b "_a"
emit_callstack "$f" 6
expect_fail "psect-binding-not-inherited" "$f" 8 2 \
	"call to annotated function _b occurs outside any function psect"

# An operandless psect directive cannot be classified, so it must not be assumed
# harmless in either direction.
f="$work/psect-malformed.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf '\tpsect\n' >> "$f"
emit_callstack "$f" 8
expect_fail "malformed-psect" "$f" 8 2 "malformed psect directive"

# A call to an annotated C function outside every function psect is structural
# drift, not runtime plumbing that may be ignored.
f="$work/known-outside.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
emit_fn "$f" _a "_main"
printf '\tpsect\truntime,class=CODE\n\tfcall\t_a\n' >> "$f"
emit_callstack "$f" 8
expect_fail "known-call-outside-psect" "$f" 8 2 \
	"call to annotated function _a occurs outside any function psect"

# Function annotations and emitted psect markers are two views of the same
# function. Missing or mismatched ownership must fail before graph traversal.
f="$work/missing-psect.s"; : > "$f"
printf '%s\n' \
	';; *************** function _main *****************' \
	';; This function is called by:' \
	';;    Startup code after reset' \
	';; This function calls:' \
	';;    Nothing' \
	'    callstack 8' >> "$f"
expect_fail "missing-function-psect" "$f" 8 2 \
	"function _main has no matching psect marker"

f="$work/mismatched-psect.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf '%s\n' \
	';; *************** function _other *****************' \
	';; This function is called by:' \
	';;    _main' \
	';; This function calls:' \
	';;    Nothing' \
	'psect	text_wrong,local,class=CODE,delta=2,merge=1,group=0' \
	'__ptext_wrong:    ;psect for function _main' \
	'    return' \
	'    callstack 8' >> "$f"
expect_fail "mismatched-function-psect" "$f" 8 2 \
	"function psect marker _main does not match annotation _other"

# --- 8. an indirect call makes the static graph incomplete ------------------
f="$work/indirect.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset" _a
emit_fn "$f" _a    "_main"
printf '\tcallw ; computed target\n' >> "$f"
emit_callstack "$f" 6
expect_fail "indirect-call" "$f" 8 2 "indirect call"

f="$work/operandless-pcall.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf '\tpcall ; computed target\n' >> "$f"
emit_callstack "$f" 8
expect_fail "operandless-pcall" "$f" 8 2 "indirect call"

f="$work/inline-callw.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf 'computed_site: CALLW ; computed target\n' >> "$f"
emit_callstack "$f" 8
expect_fail "inline-label-callw" "$f" 8 2 "indirect call"

# The second oracle is mandatory and its syntax must not drift into "not
# emitted". Otherwise a lexer miss and missing corroboration could agree on a
# false depth of zero.
f="$work/missing-callstack.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
expect_fail "missing-callstack" "$f" 8 2 "no XC8 callstack directives found"

f="$work/malformed-callstack.s"; : > "$f"
emit_fn "$f" _main "Startup code after reset"
printf '\tcallstack 0,changed\n' >> "$f"
expect_fail "malformed-callstack" "$f" 8 2 "malformed callstack directive"

# A function cannot be both reset and interrupt entry. Overwriting one
# classification with the other would lose the interrupt hardware push.
f="$work/conflicting-entry.s"; : > "$f"
printf '%s\n' \
	';; *************** function _main *****************' \
	';; This function is called by:' \
	';;    Interrupt level 1' \
	';;    Startup code after reset' \
	';; This function calls:' \
	';;    Nothing' \
	'' \
	'psect	text_main,global,class=CODE,delta=2,split=1,group=0' \
	'__ptext_main:    ;psect for function _main' \
	'    return' \
	'    callstack 8' >> "$f"
expect_fail "conflicting-entry-classification" "$f" 8 2 \
	"conflicting entry-point classifications for _main"

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
