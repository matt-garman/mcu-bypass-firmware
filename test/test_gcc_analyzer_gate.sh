#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# Prove the avr-gcc analyzer gates (analyze-gcc, attiny202-analyze-gcc) can fail.
#
# WHY THIS EXISTS. An analyzer gate that cannot fail looks exactly like a clean
# one. analyze-deep was such a gate through v0.9.17: `clang --analyze -Werror`
# prints its findings as warnings and exits 0, so it could report a null
# dereference and pass (measured 2026-10-14). avr-gcc reports -fanalyzer
# findings as warnings too. The gates fail on them only through the -Werror in
# CFLAGS_COMMON, a flag they do not own, and an analysis that hits its
# exploration limit stops in silence unless -Wanalyzer-too-complex is on. Their
# coverage also rests on CFLAGS_COMMON reaching every image rule: an image rule
# that stopped reading it would still build, unanalyzed, and both gates would
# stay green.
#
# So this runs the real gates end to end, in a scratch tree:
#   - the unmodified tree passes both, so a failure below comes from the plant;
#   - a NULL dereference planted in src/bypass_pure.c, which every AVR image
#     compiles, fails both, with exactly one diagnostic per shipping image --
#     the count is what proves the analyzer ran on each image's compile. The
#     request names one output stage (VARIANTS=cd4053_simple), so the count also
#     proves the gates analyze the full set whatever subset the caller asks for;
#   - an analysis cut short (--param=analyzer-max-enodes-per-program-point=1)
#     fails analyze-gcc with -Wanalyzer-too-complex, and passes once that flag
#     is removed from GCC_ANALYZER_FLAGS, so the flag is what fails it.
#
# The recipe passes $(CC) as $1, so a CC= override reaches the analyzer being
# proven. The recipe also skips (STRICT_TOOLS-aware) when CC cannot run
# -fanalyzer or lacks ATtiny202 device support; the scratch runs here pin
# STRICT_TOOLS=1, so nothing inside them can skip.
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
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 1 ] && [ -n "$1" ] || fail "usage: $0 CC (the recipe passes \$(CC))"
CC=$1

# The scratch tree's make must not inherit this one's request: its flags, the
# serialization wrapper's lock and verdicts, or any variable naming where an
# image is built and with what flags.
unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE MAKEFILES
unset AVR_BUILD_DIR XT_BUILD_DIR CFLAGS CFLAGS_COMMON VARIANTS AVR_REBUILD_PREREQ
while read -r name; do
	unset "$name"
done < <(compgen -e | grep '^_MAKE_SERIAL_' || true)

# shellcheck source=test/scratch_tree.sh
. "$ROOT/test/scratch_tree.sh" || fail "could not load test/scratch_tree.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-gcc-analyzer-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT
tree="$work/tree"
out="$work/out"
scratch_tree_copy "$ROOT" "$tree" \
	|| fail "could not populate the scratch tree (see test/scratch_tree.sh)"

# run_gate GOAL [VAR=value...]: the gate in the scratch tree, transcript in $out.
run_gate() {
	make --no-print-directory -C "$tree" CC="$CC" STRICT_TOOLS=1 "$@" >"$out" 2>&1
}
read_var() {
	make -s --no-print-directory -C "$tree" CC="$CC" "print-$1"
}
count() {
	grep -c -- "$1" "$out" || true
}

# One diagnostic per shipping image: the release's own image lists.
classic_images=$(read_var ATTINY13A_RELEASE_IMAGES)
classic_images="$classic_images $(read_var TINYX5_RELEASE_IMAGES)"
xt_images=$(read_var XT_RELEASE_IMAGES)
cflags_common=$(read_var CFLAGS_COMMON)
read -r -a classic <<<"$classic_images"
read -r -a xt <<<"$xt_images"
[ "${#classic[@]}" -gt 0 ] && [ "${#xt[@]}" -gt 0 ] && [ -n "$cflags_common" ] \
	|| fail "the release image lists or CFLAGS_COMMON came back empty from the scratch tree"
checks=$((checks + 1))

# --- the unmodified tree passes -----------------------------------------------
run_gate analyze-gcc \
	|| fail "analyze-gcc failed on the unmodified scratch tree, so the failures below prove nothing: $(<"$out")"
grep -q 'avr-gcc -fanalyzer (Classic AVR): clean' "$out" \
	|| fail "analyze-gcc passed without reporting a clean analysis: $(<"$out")"
checks=$((checks + 1))
run_gate attiny202-analyze-gcc \
	|| fail "attiny202-analyze-gcc failed on the unmodified scratch tree: $(<"$out")"
grep -q 'avr-gcc -fanalyzer (ATtiny202): clean' "$out" \
	|| fail "attiny202-analyze-gcc passed without reporting a clean analysis: $(<"$out")"
checks=$((checks + 1))

# --- a planted finding fails every image --------------------------------------
cat >> "$tree/src/bypass_pure.c" <<'EOF'

/* Planted by test/test_gcc_analyzer_gate.sh: a NULL dereference when c == 0. */
int bypass_planted_null_deref(int c);
int bypass_planted_null_deref(int c)
{
    static int v;
    int *p = 0;
    if (c != 0) { p = &v; }
    return *p;
}
EOF
finding='[-]Werror=analyzer-null-dereference'
subset=VARIANTS=cd4053_simple
if run_gate analyze-gcc "$subset"; then
	fail "analyze-gcc passed a planted NULL dereference: $(<"$out")"
fi
n=$(count "$finding")
[ "$n" -eq "${#classic[@]}" ] \
	|| fail "analyze-gcc ($subset) reported the planted NULL dereference $n time(s), not once for each of the ${#classic[@]} Classic images, so it did not analyze every shipping image's compile: $(<"$out")"
checks=$((checks + 1))
if run_gate attiny202-analyze-gcc "$subset"; then
	fail "attiny202-analyze-gcc passed a planted NULL dereference: $(<"$out")"
fi
n=$(count "$finding")
[ "$n" -eq "${#xt[@]}" ] \
	|| fail "attiny202-analyze-gcc ($subset) reported the planted NULL dereference $n time(s), not once for each of the ${#xt[@]} ATtiny202 images: $(<"$out")"
checks=$((checks + 1))

# --- an analysis cut short fails, and -Wanalyzer-too-complex is why -----------
scratch_tree_copy "$ROOT" "$tree" || fail "could not restore the scratch tree"
truncate_flags="$cflags_common --param=analyzer-max-enodes-per-program-point=1"
if run_gate analyze-gcc CFLAGS_COMMON="$truncate_flags"; then
	fail "analyze-gcc passed an analysis cut short by its exploration limit: $(<"$out")"
fi
[ "$(count '[-]Werror=analyzer-too-complex')" -gt 0 ] \
	|| fail "analyze-gcc failed a truncated analysis, but not with -Wanalyzer-too-complex: $(<"$out")"
checks=$((checks + 1))

sed 's/^\(override GCC_ANALYZER_FLAGS := .*\) -Wanalyzer-too-complex/\1/' \
	"$ROOT/Makefile" > "$tree/Makefile"
cmp -s "$ROOT/Makefile" "$tree/Makefile" \
	&& fail "negative fixture changed nothing -- GCC_ANALYZER_FLAGS is not spelled as this test expects"
run_gate analyze-gcc CFLAGS_COMMON="$truncate_flags" \
	|| fail "without -Wanalyzer-too-complex, a truncated analysis still failed analyze-gcc, so the flag is not what fails it: $(<"$out")"
checks=$((checks + 1))

printf 'avr-gcc analyzer gate: %d checks, 0 failures (%s; %d Classic + %d ATtiny202 images)\n' \
	"$checks" "$("$CC" --version | head -n 1)" "${#classic[@]}" "${#xt[@]}"
