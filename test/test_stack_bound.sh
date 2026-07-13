#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-stack-bound.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
build="$work/build"
mkdir -p "$tools" "$build"
checks=0
log="$work/compile.log"
unset FAKE_STACK_MODE FAKE_STACK_LOG TEST_STACK_MAX

cat > "$tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake avr-gcc 1\n'; exit 0; fi
out=
source_file= macro=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out=$2; shift 2 ;;
		-D*) macro=${1#-D}; shift ;;
		*.c) source_file=$1; shift ;;
		*) shift ;;
	esac
done
[ -n "$out" ] || exit 2
[ -z "${FAKE_STACK_LOG:-}" ] || printf '%s\t%s\n' "$source_file" "$macro" >> "$FAKE_STACK_LOG"
su=${out%.o}.su
mode=${FAKE_STACK_MODE:-pass}
if [ "$mode" = compile_fail ]; then exit 1; fi
if [ "$mode" = no_output ]; then exit 0; fi
if [ "$mode" != no_obj ]; then printf 'object\n' > "$out"; fi
case "$mode" in
	no_su) ;;
	empty_su) : > "$su" ;;
	malformed) printf 'not a stack record\n' > "$su" ;;
	nonnumeric) printf 'fake.c:1:1:fake\tunknown\tstatic\n' > "$su" ;;
	dynamic) printf 'fake.c:1:1:fake\t8\tdynamic\n' > "$su" ;;
	over) printf 'fake.c:1:1:fake\t64\tstatic\n' > "$su" ;;
	huge) printf 'fake.c:1:1:fake\t9007199254740993\tstatic\n' > "$su" ;;
	*) printf 'fake.c:1:1:fake\t8\tstatic\n' > "$su" ;;
esac
if [ "$mode" = extra_su ]; then
	printf 'extra.c:1:1:extra\t8\tstatic\n' > "$(dirname "$out")/stack_unexpected.su"
fi
if [ "$mode" = extra_obj ]; then printf 'extra object\n' > "$(dirname "$out")/stack_unexpected.o"; fi
EOF
chmod 750 "$tools/cc"

run_gate() {
	make --no-print-directory -C "$ROOT" test-stack-bound \
		STACK_BUILD_DIR="$build" STACK_MAX_FRAME="${TEST_STACK_MAX-32}" \
		CC="$tools/cc" "$@"
}

run_gate_private() {
	make --no-print-directory -C "$ROOT" test-stack-bound \
		STACK_MAX_FRAME="${TEST_STACK_MAX-32}" CC="$tools/cc"
}

seed_stale() {
	: > "$log"
	printf 'stale object\n' > "$build/stack_stale.o"
	printf 'stale.c:1:1:stale\t1\tstatic\n' > "$build/stack_stale.su"
}

assert_clean() {
	local -a artifacts
	shopt -s nullglob
	artifacts=("$build"/stack_*.o "$build"/stack_*.su)
	shopt -u nullglob
	[ "${#artifacts[@]}" -eq 0 ] \
		|| { printf 'FAIL: %s left stack artifacts\n' "$1" >&2; exit 1; }
}

expect_failure() {
	local label=$1 expected=$2 output
	shift 2
	seed_stale
	if output=$(export "$@"; run_gate 2>&1); then
		printf 'FAIL: %s was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$expected"* ]] \
		|| { printf 'FAIL: %s failed for the wrong reason: %s\n' "$label" "$output" >&2; exit 1; }
	assert_clean "$label"
	checks=$((checks + 1))
}

seed_stale
output=$(export FAKE_STACK_LOG="$log"; run_gate VARIANTS=cd4053 VARIANT=relay \
	STACK_SOURCES=src/bypass_pure.c CORE_SRC=src/bypass_pure.c \
	src_cd4053=src/bypass_pure.c src_mute=src/bypass_pure.c \
	src_relay=src/bypass_pure.c)
[[ "$output" == *"OK: 5 fresh reports"* ]] \
	|| { printf 'FAIL: valid reports did not produce the expected verdict\n' >&2; exit 1; }
expected_matrix=$'src/bypass_mcu_avr_classic.c\tCD4053_SIMPLE\nsrc/bypass_output_cd4053_simple.c\tCD4053_SIMPLE\nsrc/bypass_output_cd4053_with_mute.c\tCD4053_WITH_MUTE\nsrc/bypass_output_tq2_l2_5v_relay.c\tTQ2_L2_5V_RELAY\nsrc/bypass_pure.c\tCD4053_SIMPLE'
actual_matrix=$(LC_ALL=C sort "$log")
[[ "$actual_matrix" == "$expected_matrix" ]] \
	|| { printf 'FAIL: wrong stack compile matrix:\n%s\n' "$actual_matrix" >&2; exit 1; }
assert_clean "successful gate"
checks=$((checks + 1))

FAKE_STACK_LOG= run_gate_private >/dev/null & pid1=$!
FAKE_STACK_LOG= run_gate_private >/dev/null & pid2=$!
wait "$pid1" && wait "$pid2" \
	|| { printf 'FAIL: concurrent private stack gates interfered\n' >&2; exit 1; }
checks=$((checks + 1))

expect_failure "compiler failure" "compilation error" FAKE_STACK_MODE=compile_fail
expect_failure "successful compiler with no output" "produced no stack-check object" FAKE_STACK_MODE=no_output
expect_failure "missing object" "produced no stack-check object" FAKE_STACK_MODE=no_obj
expect_failure "missing report" "produced no stack-usage report" FAKE_STACK_MODE=no_su
expect_failure "empty report" "produced no stack-usage report" FAKE_STACK_MODE=empty_su
expect_failure "malformed report" "invalid stack-usage record" FAKE_STACK_MODE=malformed
expect_failure "nonnumeric frame" "invalid stack-usage record" FAKE_STACK_MODE=nonnumeric
expect_failure "dynamic frame" "invalid stack-usage record" FAKE_STACK_MODE=dynamic
expect_failure "oversized frame" "frame exceeds 32 B" FAKE_STACK_MODE=over
expect_failure "adjacent huge frame" "frame exceeds 9007199254740992 B" \
	FAKE_STACK_MODE=huge TEST_STACK_MAX=9007199254740992
expect_failure "unexpected extra report" "expected 5 stack-usage reports" FAKE_STACK_MODE=extra_su
expect_failure "unexpected extra object" "expected 5 stack-check objects" FAKE_STACK_MODE=extra_obj
expect_failure "zero frame limit" "positive decimal integer" TEST_STACK_MAX=0
expect_failure "malformed frame limit" "positive decimal integer" TEST_STACK_MAX=invalid

printf 'stack-bound gate validation: %d checks, 0 failures\n' "$checks"
