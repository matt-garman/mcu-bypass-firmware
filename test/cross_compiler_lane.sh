#!/usr/bin/env bash
#
# Admission check for the cross-compiler lane (`make test-cross-compiler`):
# decides whether the SECOND avr-gcc the lane would build
# the Classic images with is installed, and is genuinely a different compiler
# from the pin.
#
# The lane builds the nine Classic images with that second compiler, under the
# same device, clock, ABI and link flags, and runs the same simavr functional,
# lock-step, timing and fault-injection suites on them that `make test` runs on
# the pinned build. Both builds must pass the same tick-level golden-model
# oracle, so their observable behaviour is equivalent at the suites'
# resolution; a compiler-sensitive defect (undefined behaviour, volatile
# ordering, ISR code generation) shows up as one build failing it.
#
# Pointed at the pinned compiler, the lane would compare a compiler with itself
# and pass whatever the source did. That is refused, not warned about: by the
# version banner (the pin, matched as a whole token by the release's own
# matcher) and by the executable (the same file as CC resolves to).
#
# After the lane has built and run its images, `verify` proves the images it ran
# are the second compiler's: GCC records itself in each ELF's .comment section,
# so every image must name the second compiler's version and none the pin's.
# The lane's command-line CC= is then a checked fact, not an assumption.
#
# usage: cross_compiler_lane.sh admit ALT_BIN CC
#        cross_compiler_lane.sh verify ALT_BIN READELF ELF...
#   ALT_BIN  directory holding the second toolchain's avr-gcc, avr-objcopy and
#            avr-size (the Makefile's ALT_AVR_BIN)
#   CC       the pinned compiler, as the Makefile selects it
#   READELF  the readelf that dumps .comment (the Makefile's READELF)
#
# Exit: 0 admitted / verified, 1 refused, 2 bad invocation,
#       3 not installed (admit only; the recipe turns this into $(SKIP)).

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

usage() {
	echo "usage: cross_compiler_lane.sh admit ALT_BIN CC | verify ALT_BIN READELF ELF..." >&2
	exit 2
}
[ "$#" -ge 1 ] || usage
MODE=$1
shift
case "$MODE" in
	admit) [ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || usage ;;
	verify) [ "$#" -ge 3 ] && [ -n "$1" ] && [ -n "$2" ] || usage ;;
	*) usage ;;
esac
ALT_BIN=$1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/release-provenance.sh
. "$ROOT/scripts/release-provenance.sh"

# The pin has one home, the avr-compiler-valid gate; read it from there rather
# than restating it, so the two cannot disagree about what "the pin" is.
pin=$(sed -n 's/^AVR_GCC_PIN=\([0-9][0-9.]*\)$/\1/p' "$ROOT/test/avr_compiler_version.sh")
[ -n "$pin" ] || { echo "FAIL: could not read AVR_GCC_PIN from test/avr_compiler_version.sh" >&2; exit 1; }

refuse() {
	echo "FAIL: cross-compiler lane: $1" >&2
	exit 1
}

if [ "$MODE" = verify ]; then
	READELF=$2
	shift 2
	alt_version=$("$ALT_BIN/avr-gcc" -dumpfullversion 2>/dev/null) \
		|| refuse "$ALT_BIN/avr-gcc -dumpfullversion failed"
	[ -n "$alt_version" ] || refuse "$ALT_BIN/avr-gcc reported an empty -dumpfullversion"
	for elf in "$@"; do
		[ -f "$elf" ] && [ ! -L "$elf" ] && [ -s "$elf" ] \
			|| refuse "the lane's image is missing, empty, or not a regular file: $elf"
		comment=$("$READELF" -p .comment "$elf" 2>/dev/null) \
			|| refuse "$READELF could not dump .comment from $elf"
		compilers=$(printf '%s\n' "$comment" | sed -n 's/.*GCC: ([^)]*) \([^[:space:]]*\).*/\1/p' | sort -u)
		[ "$compilers" = "$alt_version" ] \
			|| refuse "$elf was compiled by GCC '${compilers:-unrecorded}', not the second compiler's $alt_version"
	done
	echo "cross-compiler lane: all $# images name GCC $alt_version, none the pinned $pin"
	exit 0
fi
CC=$2

for tool in avr-gcc avr-objcopy avr-size; do
	if [ ! -x "$ALT_BIN/$tool" ] || [ -d "$ALT_BIN/$tool" ]; then
		echo "cross-compiler lane: no second AVR toolchain at ALT_AVR_BIN=$ALT_BIN ($tool missing)." >&2
		echo "  Install the historic avr-gcc 7.3.0 with scripts/fetch_avr_toolchain.sh, or point" >&2
		echo "  ALT_AVR_BIN at another toolchain's bin directory." >&2
		exit 3
	fi
done

alt_cc="$ALT_BIN/avr-gcc"
banner=$( { "$alt_cc" --version 2>/dev/null || true; } | sed -n 1p)
[ -n "$banner" ] || refuse "$alt_cc printed no version banner."
if release_pinned_version_matches "$banner" "$pin"; then
	refuse "$alt_cc reports the pinned avr-gcc $pin ($banner); the lane would compare the pin with itself."
fi

alt_real=$(realpath -e -- "$alt_cc") || refuse "cannot resolve $alt_cc"
if pinned=$(command -v -- "$CC"); then
	pinned_real=$(realpath -e -- "$pinned") || refuse "cannot resolve CC=$CC ($pinned)"
	[ "$alt_real" != "$pinned_real" ] \
		|| refuse "ALT_AVR_BIN's avr-gcc is CC itself ($alt_real); the lane would compare a compiler with itself."
fi

echo "cross-compiler lane: second compiler $banner ($alt_real); pinned avr-gcc $pin"
exit 0
