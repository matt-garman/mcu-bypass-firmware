#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# Prove the clang static-analyzer gate (analyze-deep) can fail.
#
# WHY THIS EXISTS. `clang --analyze -Werror` prints an analyzer finding as a
# warning and exits 0: -Werror governs compiler diagnostics, not the analyzer's,
# on clang 18 and 21 alike. analyze-deep passed exactly those flags, so it could
# report a division by zero or a null dereference but never fail on one, and its
# green said only that the sources compiled. Measured on 2026-10-14; nothing had
# failed it because clang 18 happened to find nothing in the firmware, so nobody
# saw its warnings go unenforced. CLANG_ANALYZER_GATE_FLAGS adds
# -analyzer-werror, and silences core.FixedAddressDereference (clang 21), which
# objects to memory-mapped I/O itself.
#
# TWO HALVES, because either alone leaves the hole open. The behavioural half
# analyzes planted translation units under the gate's own flags, read from the
# Makefile, for the gate's own AVR target: a division by zero must fail, a
# trivially clean unit must pass (so the failure comes from the finding, not
# from a flag this clang rejects), and a volatile register read-modify-write --
# what every avr-libc SFR macro expands to -- must pass. Where this clang has
# core.FixedAddressDereference, that same register unit must fail without the
# silence list, or the silencing is not what keeps the gate green. The contract
# half proves the analyze-deep recipe still hands the flags to `clang
# --analyze`, so deleting them from the recipe cannot leave the behavioural half
# proving flags nobody uses; a mutated recipe proves that check can fail.
#
# The recipe passes $(CLANG) as $1 rather than this script re-deriving it, so a
# CLANG= override reaches the analyzer that is being proven.
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

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAKEFILE="$ROOT/Makefile"
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] && [ -n "$1" ] || fail "usage: $0 CLANG (the recipe passes \$(CLANG))"
CLANG=$1

read_var() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
		make -s --no-print-directory -C "$ROOT" "print-$1"
	)
}
GATE_FLAGS=$(read_var CLANG_ANALYZER_GATE_FLAGS)
MCU=$(read_var ATTINY13A_MCU)
[[ "$GATE_FLAGS" == *-analyzer-werror* ]] \
	|| fail "CLANG_ANALYZER_GATE_FLAGS no longer carries -analyzer-werror: $GATE_FLAGS"
[[ "$GATE_FLAGS" == *silence-checkers=core.FixedAddressDereference* ]] \
	|| fail "CLANG_ANALYZER_GATE_FLAGS no longer silences core.FixedAddressDereference: $GATE_FLAGS"
[ -n "$MCU" ] || fail "print-ATTINY13A_MCU came back empty"
checks=$((checks + 1))

# --- contract half -----------------------------------------------------------
# Print each `$(CLANG) --analyze` invocation in the analyze-deep recipe, joined
# across its backslash continuations, and say whether it carries the gate flags.
recipe_verdicts() {
	awk '
	/^analyze-deep:/ { in_recipe = 1; next }
	in_recipe && !/^\t/ { in_recipe = 0 }
	!in_recipe { next }
	{
		line = $0
		if (pending != "") { pending = pending " " line }
		else if (index(line, "$(CLANG) --analyze")) { pending = line }
		if (pending != "" && line !~ /\\$/) {
			print (index(pending, "$(CLANG_ANALYZER_GATE_FLAGS)") ? "carries" : "MISSING")
			pending = ""
		}
	}
	' "$1"
}
mapfile -t verdicts < <(recipe_verdicts "$MAKEFILE")
[ "${#verdicts[@]}" -ge 1 ] \
	|| fail "found no \$(CLANG) --analyze invocation in the analyze-deep recipe -- the recipe walk has stopped matching"
for verdict in "${verdicts[@]}"; do
	[ "$verdict" = carries ] \
		|| fail "an analyze-deep \`\$(CLANG) --analyze\` invocation does not pass \$(CLANG_ANALYZER_GATE_FLAGS), so its findings cannot fail the gate"
done
checks=$((checks + 1))

scratch=$(mktemp -d "${TMPDIR:-/tmp}/test-analyzer-gate.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
sed 's/[$](CLANG_ANALYZER_GATE_FLAGS)//' "$MAKEFILE" > "$scratch/Makefile"
cmp -s "$MAKEFILE" "$scratch/Makefile" \
	&& fail "negative fixture changed nothing -- the gate flags are not spelled as this test expects"
mapfile -t mutated < <(recipe_verdicts "$scratch/Makefile")
[[ " ${mutated[*]-} " == *" MISSING "* ]] \
	|| fail "the contract check did not report a recipe stripped of its gate flags -- it cannot fail"
checks=$((checks + 1))

# --- behavioural half ---------------------------------------------------------
printf 'int planted(int c) { int z = 0; return c / z; }\n' > "$scratch/finding.c"
printf 'int planted(int c) { return c + 1; }\n' > "$scratch/clean.c"
printf 'void planted(void) { *(volatile unsigned char *)0x38 |= 1u; }\n' > "$scratch/mmio.c"

# analyze FILE FLAGS... -- the gate's invocation shape for its own AVR target.
analyze() {
	local file=$1
	shift
	"$CLANG" --analyze -Xclang -analyzer-output=text -Werror "$@" \
		-target avr -mmcu="$MCU" "$scratch/$file" -o /dev/null >"$scratch/out" 2>&1
}
read -r -a gate <<<"$GATE_FLAGS"

if analyze finding.c "${gate[@]}"; then
	fail "a planted division by zero passed the gate flags: $(<"$scratch/out")"
fi
checks=$((checks + 1))

analyze clean.c "${gate[@]}" \
	|| fail "a clean unit failed the gate flags, so the planted failure above proves nothing: $(<"$scratch/out")"
checks=$((checks + 1))

analyze mmio.c "${gate[@]}" \
	|| fail "a volatile register read-modify-write failed the gate flags; every SFR access in the firmware would too: $(<"$scratch/out")"
checks=$((checks + 1))

if "$CLANG" -cc1 -analyzer-checker-help 2>/dev/null \
		| grep -qw 'core.FixedAddressDereference'; then
	if analyze mmio.c -Xclang -analyzer-werror; then
		fail "this clang has core.FixedAddressDereference, yet a register read-modify-write passed without the silence list -- the silencing is not load-bearing as documented"
	fi
	checks=$((checks + 1))
	silencing="silencing proven load-bearing"
else
	silencing="core.FixedAddressDereference absent on this clang"
fi

printf 'analyzer gate: %d checks, 0 failures (%s; %s)\n' \
	"$checks" "$("$CLANG" --version | head -n 1)" "$silencing"
