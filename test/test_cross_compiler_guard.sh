#!/usr/bin/env bash
#
# Host-only regression for test/cross_compiler_lane.sh, the admission check of
# `make test-cross-compiler`.
#
# THE DEFECT IT GUARDS. A cross-compiler lane passes whatever the source does if
# its "second" compiler is the pinned one: it then compares a compiler with
# itself and proves nothing about compiler sensitivity, while reporting a
# green comparison. The lane must therefore refuse a second compiler that
# reports the pin or IS the pinned executable, must not mistake an absent
# toolchain for a pass, and must confirm afterwards that the images it ran
# name the second compiler. Fake toolchains and a fake readelf drive every
# branch, and the Makefile recipe is driven too, so the absent case is a clean
# skip only when STRICT_TOOLS is unset.

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
LANE="$ROOT/test/cross_compiler_lane.sh"
REAL_MAKE=$(command -v make) || { echo "FAIL: make is required" >&2; exit 1; }
checks=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/test-cross-compiler-guard.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
output="$work/output"

[ -x "$LANE" ] || fail "test/cross_compiler_lane.sh is missing or not executable"
pin=$(sed -n 's/^AVR_GCC_PIN=\([0-9][0-9.]*\)$/\1/p' "$ROOT/test/avr_compiler_version.sh")
[ -n "$pin" ] || fail "could not read AVR_GCC_PIN from test/avr_compiler_version.sh"

# make_toolchain DIR BANNER: a fake second toolchain whose avr-gcc prints
# BANNER (nothing when empty), plus the avr-objcopy and avr-size the lane needs.
make_toolchain() {
	local dir=$1 banner=$2
	mkdir -p "$dir"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'if [ "${1-}" = --version ]; then'
		[ -z "$banner" ] || printf '\tprintf %s\n' "'${banner}\\nCopyright (C) the fake\\n'"
		printf '%s\n' 'fi'
		printf '%s\n' 'if [ "${1-}" = -dumpfullversion ]; then'
		[ -z "$banner" ] || printf '\techo %s\n' "'${banner##* }'"
		printf '%s\n' 'fi'
		printf '%s\n' 'exit 0'
	} > "$dir/avr-gcc"
	printf '#!/bin/sh\nexit 0\n' > "$dir/avr-objcopy"
	printf '#!/bin/sh\nexit 0\n' > "$dir/avr-size"
	chmod +x "$dir/avr-gcc" "$dir/avr-objcopy" "$dir/avr-size"
}
# lane ALT_BIN CC: run the admission check; sets rc.
lane() {
	rc=0
	"$LANE" admit "$1" "$2" >"$output" 2>&1 || rc=$?
}

primary="$work/primary/avr-gcc"
make_toolchain "$work/primary" "avr-gcc (GCC) $pin"

# Admitted: a genuinely different compiler, named in the report.
make_toolchain "$work/historic" 'avr-gcc (GCC) 7.3.0'
lane "$work/historic" "$primary"
[ "$rc" -eq 0 ] && grep -Fq 'second compiler avr-gcc (GCC) 7.3.0' "$output" \
		&& grep -Fq "pinned avr-gcc $pin" "$output" \
	|| fail "a genuine second compiler was not admitted and named (rc=$rc): $(cat "$output")"
checks=$((checks + 1))

# Not installed: rc 3, the skip the recipe maps through $(SKIP), with the fix.
lane "$work/nowhere" "$primary"
[ "$rc" -eq 3 ] && grep -Fq 'scripts/fetch_avr_toolchain.sh' "$output" \
	|| fail "an absent second toolchain was not reported as not installed (rc=$rc): $(cat "$output")"
make_toolchain "$work/partial" 'avr-gcc (GCC) 7.3.0'
rm "$work/partial/avr-size"
lane "$work/partial" "$primary"
[ "$rc" -eq 3 ] && grep -Fq 'avr-size missing' "$output" \
	|| fail "a second toolchain without avr-size was not reported as incomplete (rc=$rc): $(cat "$output")"
checks=$((checks + 1))

# Refused: the pin itself, whatever the packaging blob says.
for banner in "avr-gcc (GCC) $pin" "avr-gcc (Ubuntu $pin-1ubuntu1) $pin"; do
	make_toolchain "$work/pinned" "$banner"
	lane "$work/pinned" "$primary"
	[ "$rc" -eq 1 ] && grep -Fq 'compare the pin with itself' "$output" \
		|| fail "a second compiler reporting the pin ($banner) was admitted (rc=$rc): $(cat "$output")"
done
checks=$((checks + 1))

# Refused: CC itself under another name, even when its banner is not the pin.
ln -s "$work/historic/avr-gcc" "$work/cc-alias"
lane "$work/historic" "$work/cc-alias"
[ "$rc" -eq 1 ] && grep -Fq 'is CC itself' "$output" \
	|| fail "a second compiler that is CC itself was admitted (rc=$rc): $(cat "$output")"
checks=$((checks + 1))

# Refused: a compiler that names no version cannot be shown to be another one.
make_toolchain "$work/silent" ''
lane "$work/silent" "$primary"
[ "$rc" -eq 1 ] && grep -Fq 'printed no version banner' "$output" \
	|| fail "a silent second compiler was admitted (rc=$rc): $(cat "$output")"
checks=$((checks + 1))

# Malformed invocations: one argument, or an empty one.
malformed() {
	rc=0
	"$LANE" "$@" >"$output" 2>&1 || rc=$?
	[ "$rc" -eq 2 ] || fail "the lane did not reject the malformed call ($*) with rc 2 (rc=$rc)"
}
malformed admit one
malformed admit one ''
malformed admit '' two
malformed verify "$work/historic" readelf
malformed bogus "$work/historic" "$primary"
malformed
checks=$((checks + 1))

# verify: every image the lane ran must name the second compiler, and only it.
# A fake readelf answers with the .comment recorded for each fake image.
cat > "$work/readelf" <<'FAKE_READELF'
#!/usr/bin/env bash
[ "$1" = -p ] && [ "$2" = .comment ] || exit 2
[ -s "$3.comment" ] || exit 0
printf "\nString dump of section '.comment':\n"
while IFS= read -r line; do printf '  [     0]  %s\n' "$line"; done < "$3.comment"
FAKE_READELF
chmod +x "$work/readelf"
# image NAME COMMENT...: a fake ELF whose .comment holds the given lines.
image() {
	local name=$1
	shift
	printf 'ELF' > "$work/$name.elf"
	printf '%s\n' "$@" > "$work/$name.elf.comment"
}
verify() {
	rc=0
	"$LANE" verify "$work/historic" "$work/readelf" "$@" >"$output" 2>&1 || rc=$?
}
image alt-a 'GCC: (GNU) 7.3.0'
image alt-b 'GCC: (GNU) 7.3.0' 'GCC: (GNU) 7.3.0'
verify "$work/alt-a.elf" "$work/alt-b.elf"
[ "$rc" -eq 0 ] && grep -Fq 'all 2 images name GCC 7.3.0' "$output" \
	|| fail "images the second compiler built were not verified (rc=$rc): $(cat "$output")"
image pinned-img "GCC: (GNU) $pin"
verify "$work/alt-a.elf" "$work/pinned-img.elf"
[ "$rc" -eq 1 ] && grep -Fq "compiled by GCC '$pin'" "$output" \
	|| fail "an image the pinned compiler built passed verification (rc=$rc): $(cat "$output")"
image mixed 'GCC: (GNU) 7.3.0' "GCC: (GNU) $pin"
verify "$work/mixed.elf"
[ "$rc" -eq 1 ] \
	|| fail "an image naming two compilers passed verification (rc=$rc): $(cat "$output")"
image unrecorded
verify "$work/unrecorded.elf"
[ "$rc" -eq 1 ] && grep -Fq "compiled by GCC 'unrecorded'" "$output" \
	|| fail "an image with no compiler record passed verification (rc=$rc): $(cat "$output")"
verify "$work/alt-a.elf" "$work/no-such-image.elf"
[ "$rc" -eq 1 ] && grep -Fq 'missing, empty, or not a regular file' "$output" \
	|| fail "a missing lane image passed verification (rc=$rc): $(cat "$output")"
checks=$((checks + 1))

# The recipe verifies the images AFTER the sub-make that builds and runs them,
# and passes it the very list the sub-make builds. Lexical, because exercising
# it end to end is the lane itself (a full Classic build and simulation).
recipe=$(awk '/^test-cross-compiler:/{on=1; next} on && !/^\t/{exit} on' "$ROOT/Makefile")
make_line=$(printf '%s\n' "$recipe" | { grep -n 'test-sim-attiny13a test-sim-tinyx5 test-fault-inject' || true; } | cut -d: -f1)
verify_line=$(printf '%s\n' "$recipe" | { grep -n "cross_compiler_lane.sh verify '\$(ALT_AVR_BIN)' '\$(READELF)' \$(ALT_AVR_ELFS)" || true; } | cut -d: -f1)
[ -n "$make_line" ] && [ -n "$verify_line" ] && [ "$verify_line" -gt "$make_line" ] \
	|| fail "the test-cross-compiler recipe does not verify the lane's images after running them"
checks=$((checks + 1))

# The recipe: an absent toolchain is $(SKIP) -- clean without STRICT_TOOLS,
# fatal with it -- and a refusal fails before any build starts.
lane_make() {
	rc=0
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL STRICT_TOOLS CC
		"$REAL_MAKE" --no-print-directory -s -C "$ROOT" test-cross-compiler "$@"
	) >"$output" 2>&1 || rc=$?
}
lane_make ALT_AVR_BIN="$work/nowhere"
[ "$rc" -eq 0 ] && grep -Fq 'no second AVR toolchain' "$output" \
	|| fail "an absent second toolchain was not a clean skip without STRICT_TOOLS (rc=$rc): $(cat "$output")"
lane_make ALT_AVR_BIN="$work/nowhere" STRICT_TOOLS=1
[ "$rc" -ne 0 ] && grep -Fq 'STRICT_TOOLS=1' "$output" \
	|| fail "an absent second toolchain passed under STRICT_TOOLS=1 (rc=$rc): $(cat "$output")"
lane_make ALT_AVR_BIN="$work/pinned"
[ "$rc" -ne 0 ] && grep -Fq 'compare the pin with itself' "$output" \
		&& ! grep -Fq 'cross-compiler lane: the Classic images' "$output" \
	|| fail "the recipe ran the lane on the pinned compiler (rc=$rc): $(cat "$output")"
checks=$((checks + 1))

echo "cross-compiler lane guard: $checks checks, 0 failures"
