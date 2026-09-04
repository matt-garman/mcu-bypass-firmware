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

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-$HOME}/test-attiny202-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
dfp="$work/dfp"
build="$work/build"
cc_log="$work/cc.log"
mkdir -p "$tools" "$dfp/gcc/dev/attiny202/device-specs" "$dfp/include/avr"
: > "$dfp/gcc/dev/attiny202/device-specs/specs-attiny202"
: > "$dfp/include/avr/iotn202.h"
: > "$cc_log"
export FAKE_CC_LOG="$cc_log"
checks=0
unset FAKE_CC_MODE FAKE_READELF_MODE FAKE_SIZE_MODE FAKE_OBJCOPY_MODE
unset TEST_VARIANTS TEST_DFP XT_FLASH_BYTES XT_STATIC_RAM_LIMIT XT_SRAM_BYTES
# Parent Make command-line assignments propagate through these variables and
# must not override the isolated negative fixtures passed to each nested build.
unset MAKEFLAGS MAKEOVERRIDES MFLAGS GNUMAKEFLAGS
# The skip-policy checks below pin STRICT_TOOLS explicitly; clear any ambient
# value (scripts/ci-local.sh exports STRICT_TOOLS=1) so nothing inherits it.
unset STRICT_TOOLS

cat > "$tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake avr-gcc 1\n'; exit 0; fi
out=
args=$*
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
printf '%s\t%s\n' "$out" "$args" >> "${FAKE_CC_LOG:?}"
case "${FAKE_CC_MODE:-pass}" in
	fail) printf 'partial ELF\n' > "$out"; exit 1 ;;
	empty) : > "$out" ;;
	*) printf 'fresh ELF\n' > "$out" ;;
esac
EOF

cat > "$tools/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_READELF_MODE:-pass}" in
	fail) exit 1 ;;
	wrong) printf '  Flags: 0x0, avr:5\n' ;;
	*) printf '  Flags: 0x0, avr:103\n' ;;
esac
EOF

cat > "$tools/size" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FAKE_SIZE_MODE:-pass}" in
	fail) printf 'size failed\n' >&2; exit 1 ;;
	empty) exit 0 ;;
	malformed) printf 'Program: nope bytes (4.9%% Full)\nData: 8 bytes (6.2%% Full)\n' ;;
	program_duplicate) printf 'Program: 100 bytes (4.9%% Full)\nProgram: 100 bytes (4.9%% Full)\nData: 8 bytes (6.2%% Full)\n' ;;
	program_trailing) printf 'Program: 100 bytes (4.9%% Full) garbage\nData: 8 bytes (6.2%% Full)\n' ;;
	program_zero) printf 'Program: 0 bytes (0.0%% Full)\nData: 8 bytes (6.2%% Full)\n' ;;
	over) printf 'Program: 4096 bytes (200.0%% Full)\nData: 8 bytes (6.2%% Full)\n' ;;
	huge|adjacent) printf 'Program: 999999999999999999999999999999999999 bytes (100.0%% Full)\nData: 8 bytes (6.2%% Full)\n' ;;
	ram_missing) printf 'Program: 100 bytes (4.9%% Full)\n' ;;
	ram_duplicate) printf 'Program: 100 bytes (4.9%% Full)\nData: 8 bytes (6.2%% Full)\nData: 8 bytes (6.2%% Full)\n' ;;
	ram_malformed) printf 'Program: 100 bytes (4.9%% Full)\nData: nope bytes (6.2%% Full)\n' ;;
	ram_trailing) printf 'Program: 100 bytes (4.9%% Full)\nData: 8 bytes (6.2%% Full) garbage\n' ;;
	ram_zero) printf 'Program: 100 bytes (4.9%% Full)\nData: 0 bytes (0.0%% Full)\n' ;;
	ram_boundary) printf 'Program: 100 bytes (4.9%% Full)\nData: 16 bytes (12.5%% Full)\n' ;;
	ram_over) printf 'Program: 100 bytes (4.9%% Full)\nData: 17 bytes (13.3%% Full)\n' ;;
	ram_huge) printf 'Program: 100 bytes (4.9%% Full)\nData: 999999999999999999999999999999999999 bytes (100.0%% Full)\n' ;;
	*) printf 'AVR Memory Usage\nDevice: Unknown\n\nProgram: 100 bytes\nData: 8 bytes\n' ;;
esac
EOF

cat > "$tools/objcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do out=$arg; done
case "${FAKE_OBJCOPY_MODE:-pass}" in
	fail) printf 'partial HEX\n' > "$out"; exit 1 ;;
	empty) : > "$out" ;;
	invalid) printf 'not Intel HEX\n' > "$out" ;;
	short) printf ':0\n:00000001FF\n' > "$out" ;;
	bad_checksum) printf ':0100000001FF\n:00000001FF\n' > "$out" ;;
	undefined_type) printf ':00000006FA\n:00000001FF\n' > "$out" ;;
	bad_extended) printf ':00000004FC\n:00000001FF\n' > "$out" ;;
	eof_only) printf ':00000001FF\n' > "$out" ;;
	trailing) printf ':0100000001FE\n:00000001FF\ntrailing garbage\n' > "$out" ;;
	*) printf ':0100000001FE\n:00000001FF\n' > "$out" ;;
esac
EOF
chmod 750 "$tools"/*

run_build() {
	make --no-print-directory -C "$ROOT" attiny202 \
		XT_BUILD_DIR="$build" XT_DFP="${TEST_DFP-$dfp}" VARIANTS="${TEST_VARIANTS-cd4053_simple}" \
		CC="$tools/cc" READELF="$tools/readelf" SIZE="$tools/size" \
		OBJCOPY="$tools/objcopy" "$@"
}

latest_cc_command() {
	local output=$1 logged_output logged_command latest=
	while IFS=$'\t' read -r logged_output logged_command; do
		if [ "$logged_output" = "$output" ]; then latest=$logged_command; fi
	done < "$cc_log"
	[ -n "$latest" ] || return 1
	printf '%s\n' "$latest"
}

command_has_arg() {
	case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

seed_stale() {
	mkdir -p "$build"
	printf 'stale ELF\n' > "$build/bypass-attiny202-cd4053_simple.elf"
	printf ':00000001FF\n' > "$build/bypass-attiny202-cd4053_simple.hex"
}

assert_no_artifacts() {
	[ ! -e "$build/bypass-attiny202-cd4053_simple.elf" ] \
		|| { printf 'FAIL: %s left a stale ELF\n' "$1" >&2; exit 1; }
	[ ! -e "$build/bypass-attiny202-cd4053_simple.hex" ] \
		|| { printf 'FAIL: %s left a stale HEX\n' "$1" >&2; exit 1; }
	[ ! -e "$build/bypass-attiny202-cd4053_simple.elf.tmp" ] \
		|| { printf 'FAIL: %s left a temporary ELF\n' "$1" >&2; exit 1; }
	[ ! -e "$build/bypass-attiny202-cd4053_simple.hex.tmp" ] \
		|| { printf 'FAIL: %s left a temporary HEX\n' "$1" >&2; exit 1; }
	[ ! -e "$build/cd4053_simple.log" ] \
		|| { printf 'FAIL: %s left a compiler log\n' "$1" >&2; exit 1; }
}

expect_failure() {
	local label=$1 expected=$2 output
	shift 2
	seed_stale
	if output=$(export "$@"; run_build 2>&1); then
		printf 'FAIL: %s was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$expected"* ]] \
		|| { printf 'FAIL: %s failed for the wrong reason: %s\n' "$label" "$output" >&2; exit 1; }
	assert_no_artifacts "$label"
	checks=$((checks + 1))
}

expect_success() {
	local label=$1 expected=$2 output
	shift 2
	seed_stale
	if ! output=$(export "$@"; run_build 2>&1); then
		printf 'FAIL: %s was rejected: %s\n' "$label" "$output" >&2
		exit 1
	fi
	[[ "$output" == *"$expected"* ]] \
		|| { printf 'FAIL: %s omitted expected result: %s\n' "$label" "$output" >&2; exit 1; }
	[ -s "$build/bypass-attiny202-cd4053_simple.elf" ] \
		&& [ -s "$build/bypass-attiny202-cd4053_simple.hex" ] \
		|| { printf 'FAIL: %s did not publish both artifacts\n' "$label" >&2; exit 1; }
	checks=$((checks + 1))
}

seed_stale
: > "$cc_log"
(export TEST_VARIANTS="cd4053_simple cd4053_with_mute tq2_l2_5v_relay"; run_build) >/dev/null
# The stage field of the canonical basename IS the variant name, so these are
# composed directly. Still spelled against a literal `bypass-attiny202-` prefix
# rather than asking the Makefile: this test's job includes proving the build
# emits the names the release contract names.
for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
	stem="$build/bypass-attiny202-${variant}"
	[ -s "$stem.elf" ] \
		|| { printf 'FAIL: missing fresh %s ELF\n' "$variant" >&2; exit 1; }
	grep -q '^fresh ELF$' "$stem.elf" \
		|| { printf 'FAIL: stale %s ELF survived\n' "$variant" >&2; exit 1; }
	grep -q '^:0100000001FE$' "$stem.hex" \
		|| { printf 'FAIL: stale %s HEX survived\n' "$variant" >&2; exit 1; }
	grep -Eq '^:00000001[Ff][Ff]\r?$' "$stem.hex" \
		|| { printf 'FAIL: missing fresh valid %s HEX\n' "$variant" >&2; exit 1; }
	case "$variant" in
		cd4053_simple)
			expected_macro=CD4053_SIMPLE
			expected_driver=src/bypass_output_cd4053_simple.c
			;;
		cd4053_with_mute)
			expected_macro=CD4053_WITH_MUTE
			expected_driver=src/bypass_output_cd4053_with_mute.c
			;;
		tq2_l2_5v_relay)
			expected_macro=TQ2_L2_5V_RELAY
			expected_driver=src/bypass_output_tq2_l2_5v_relay.c
			;;
	esac
	command=$(latest_cc_command "$stem.elf.tmp") \
		|| { printf 'FAIL: missing ATtiny202 compiler command for %s\n' "$variant" >&2; exit 1; }
	command_has_arg "$command" "-D$expected_macro" \
		&& command_has_arg "$command" "$expected_driver" \
		|| { printf 'FAIL: ATtiny202 compiler used the wrong selector/source pair for %s\n' \
			"$variant" >&2; exit 1; }
	for unexpected_macro in CD4053_SIMPLE CD4053_WITH_MUTE TQ2_L2_5V_RELAY; do
		if [ "$unexpected_macro" != "$expected_macro" ] \
				&& command_has_arg "$command" "-D$unexpected_macro"; then
			printf 'FAIL: ATtiny202 compiler mixed selector macros for %s\n' "$variant" >&2
			exit 1
		fi
	done
	for unexpected_driver in \
			src/bypass_output_cd4053_simple.c \
			src/bypass_output_cd4053_with_mute.c \
			src/bypass_output_tq2_l2_5v_relay.c; do
		if [ "$unexpected_driver" != "$expected_driver" ] \
				&& command_has_arg "$command" "$unexpected_driver"; then
			printf 'FAIL: ATtiny202 compiler mixed driver sources for %s\n' "$variant" >&2
			exit 1
		fi
	done
	checks=$((checks + 1))
done
[ "$(wc -l < "$cc_log")" -eq 3 ] \
	|| { printf 'FAIL: ATtiny202 build issued an unexpected number of compiler commands\n' >&2; exit 1; }
checks=$((checks + 1))

# The production target must consume XT_HEADERS, not merely use it for static
# analysis. A missing shared-header dependency must stop before any compiler
# command can publish a replacement image.
before=$(wc -l < "$cc_log")
if output=$(run_build XT_HEADERS="$work/missing-modular-header" 2>&1); then
	printf 'FAIL: ATtiny202 build ignored a missing XT_HEADERS prerequisite\n' >&2
	exit 1
fi
[[ "$output" == *"No rule to make target"* \
	&& "$output" == *"missing-modular-header"* ]] \
	|| { printf 'FAIL: missing XT_HEADERS prerequisite failed for the wrong reason: %s\n' \
		"$output" >&2; exit 1; }
[ "$(wc -l < "$cc_log")" -eq "$before" ] \
	|| { printf 'FAIL: missing XT_HEADERS prerequisite still reached the compiler\n' >&2; exit 1; }
checks=$((checks + 1))

expect_failure "compiler failure" "did not compile" FAKE_CC_MODE=fail
expect_failure "empty compiler output" "produced no ELF" FAKE_CC_MODE=empty
expect_failure "readelf failure" "could not inspect ELF" FAKE_READELF_MODE=fail
expect_failure "wrong architecture" "is not avrxmega3" FAKE_READELF_MODE=wrong
expect_failure "size command failure" "could not measure Program size" FAKE_SIZE_MODE=fail
expect_failure "missing size output" "expected exactly one Program size record" FAKE_SIZE_MODE=empty
expect_failure "malformed size output" "malformed Program size record" FAKE_SIZE_MODE=malformed
expect_failure "duplicate Program record" "expected exactly one Program size record, found 2" FAKE_SIZE_MODE=program_duplicate
expect_failure "trailing Program garbage" "malformed Program size record" FAKE_SIZE_MODE=program_trailing
expect_failure "zero Program usage" "Program size must be a positive decimal integer" FAKE_SIZE_MODE=program_zero
expect_failure "flash budget overflow" "exceeds 2048 B" FAKE_SIZE_MODE=over
expect_failure "huge size overflow" "exceeds 2048 B" FAKE_SIZE_MODE=huge
expect_failure "adjacent huge size overflow" "exceeds 999999999999999999999999999999999998 B" \
	FAKE_SIZE_MODE=adjacent XT_FLASH_BYTES=999999999999999999999999999999999998

expect_failure "missing Data record" "expected exactly one Data size record, found 0" FAKE_SIZE_MODE=ram_missing
expect_failure "duplicate Data record" "expected exactly one Data size record, found 2" FAKE_SIZE_MODE=ram_duplicate
expect_failure "malformed Data record" "malformed Data size record" FAKE_SIZE_MODE=ram_malformed
expect_failure "trailing Data garbage" "malformed Data size record" FAKE_SIZE_MODE=ram_trailing
expect_failure "zero static RAM usage" "Data size must be a positive decimal integer" FAKE_SIZE_MODE=ram_zero
expect_success "static RAM policy boundary" "static RAM 16/16 B (128 B device)" FAKE_SIZE_MODE=ram_boundary
expect_failure "static RAM policy overflow" "exceeds 16 B policy limit" FAKE_SIZE_MODE=ram_over
expect_failure "huge static RAM overflow" "exceeds 16 B policy limit" FAKE_SIZE_MODE=ram_huge
expect_success "immutable device SRAM" "static RAM 8/16 B (128 B device)" XT_SRAM_BYTES=1
expect_failure "objcopy failure" "could not generate HEX" FAKE_OBJCOPY_MODE=fail
expect_failure "empty HEX output" "empty or invalid HEX" FAKE_OBJCOPY_MODE=empty
expect_failure "invalid HEX output" "empty or invalid HEX" FAKE_OBJCOPY_MODE=invalid
expect_failure "short HEX record" "empty or invalid HEX" FAKE_OBJCOPY_MODE=short
expect_failure "bad HEX checksum" "empty or invalid HEX" FAKE_OBJCOPY_MODE=bad_checksum
expect_failure "undefined HEX record type" "empty or invalid HEX" FAKE_OBJCOPY_MODE=undefined_type
expect_failure "invalid extended-address record" "empty or invalid HEX" FAKE_OBJCOPY_MODE=bad_extended
expect_failure "EOF-only HEX" "empty or invalid HEX" FAKE_OBJCOPY_MODE=eof_only
expect_failure "trailing HEX content" "empty or invalid HEX" FAKE_OBJCOPY_MODE=trailing

# Every HEX case above is decided by scripts/validate-ihex.sh, the one validator
# the Classic AVR .hex rules and both PIC builds also use. Because it is an
# external file rather than an inline parser, its PRESENCE has to be checked
# rather than assumed -- an absent or non-executable validator must fail the
# build loudly, not wave an unvalidated image through. The counterpart of
# test_pic_build.sh's missing-validator check.
#
# The guard deliberately lives inside the recipe rather than as a Make
# prerequisite: the recipe removes stale artifacts as its FIRST action, so a
# validator failure still leaves nothing behind, which assert_no_artifacts pins.
expect_missing_validator() {
	local label=$1 path=$2 output
	seed_stale
	if output=$(run_build IHEX_VALIDATOR="$path" 2>&1); then
		printf 'FAIL: %s was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"Intel HEX validator not found"* ]] \
		|| { printf 'FAIL: %s failed for the wrong reason: %s\n' "$label" "$output" >&2; exit 1; }
	assert_no_artifacts "$label"
	checks=$((checks + 1))
}

printf 'not executable\n' > "$work/unexecutable-validator"
chmod 640 "$work/unexecutable-validator"
expect_missing_validator "absent Intel HEX validator" "$work/missing-validator"
expect_missing_validator "non-executable Intel HEX validator" \
	"$work/unexecutable-validator"

expect_failure "zero flash budget" "positive decimal integer" XT_FLASH_BYTES=0
expect_failure "malformed flash budget" "positive decimal integer" XT_FLASH_BYTES=invalid
expect_failure "zero static RAM policy" "positive decimal integer no greater than the 128 B device SRAM" XT_STATIC_RAM_LIMIT=0
expect_failure "malformed static RAM policy" "positive decimal integer no greater than the 128 B device SRAM" XT_STATIC_RAM_LIMIT=invalid
expect_failure "static RAM policy above device" "positive decimal integer no greater than the 128 B device SRAM" XT_STATIC_RAM_LIMIT=129
expect_failure "huge static RAM policy" "positive decimal integer no greater than the 128 B device SRAM" \
	XT_STATIC_RAM_LIMIT=999999999999999999999999999999999999
expect_failure "unsupported variant" "unsupported ATtiny202 variant" TEST_VARIANTS=bogus
expect_failure "redirect-like variant" "unsupported ATtiny202 variant" \
	"TEST_VARIANTS=cd4053_simple >$work/injected"
[ ! -e "$work/injected" ] || { printf 'FAIL: variant text executed a redirection\n' >&2; exit 1; }
expect_failure "duplicate variant" "duplicate ATtiny202 variant" \
	"TEST_VARIANTS=cd4053_simple cd4053_simple"
expect_failure "empty variant matrix" "VARIANTS is empty" TEST_VARIANTS=

seed_stale
if output=$(run_build VARIANTS=bogus XT_VARIANTS_UNKNOWN= \
		XT_VARIANTS_REQUESTED=cd4053_simple 2>&1); then
	printf 'FAIL: command-line variant guard overrides were accepted\n' >&2
	exit 1
fi
[[ "$output" == *"unsupported ATtiny202 variant"* ]] \
	|| { printf 'FAIL: guard override failed for the wrong reason: %s\n' "$output" >&2; exit 1; }
assert_no_artifacts "command-line variant guard overrides"
checks=$((checks + 1))

for assignment in 'XT_FLASH_BYTES="' 'TEST_VARIANTS="'; do
	seed_stale
	if output=$(export "$assignment"; run_build 2>&1); then
		printf 'FAIL: malformed override %s was accepted\n' "$assignment" >&2
		exit 1
	fi
	assert_no_artifacts "malformed override $assignment"
	checks=$((checks + 1))
done

# Absent DFP skips cleanly by default, but is a HARD FAILURE under STRICT_TOOLS=1
# (the policy scripts/ci-local.sh runs with). Pin STRICT_TOOLS on the make command
# line for both so the ambient CI environment cannot flip either expectation.
seed_stale
run_build_output=$(export TEST_DFP="$work/missing-dfp"; run_build STRICT_TOOLS= 2>&1) \
	|| { printf 'FAIL: absent DFP did not skip cleanly: %s\n' "$run_build_output" >&2; exit 1; }
[[ "$run_build_output" == *"skipping ATtiny202 build"* ]] \
	|| { printf 'FAIL: absent DFP skip missing its reason: %s\n' "$run_build_output" >&2; exit 1; }
assert_no_artifacts "absent DFP skip"
checks=$((checks + 1))

seed_stale
if output=$(export TEST_DFP="$work/missing-dfp"; run_build STRICT_TOOLS=1 2>&1); then
	printf 'FAIL: absent DFP under STRICT_TOOLS=1 did not fail: %s\n' "$output" >&2
	exit 1
fi
[[ "$output" == *"STRICT_TOOLS=1"* ]] \
	|| { printf 'FAIL: STRICT_TOOLS=1 absent DFP failed for the wrong reason: %s\n' "$output" >&2; exit 1; }
assert_no_artifacts "absent DFP strict"
checks=$((checks + 1))

seed_stale
rm -f "$build/bypass-attiny202-cd4053_simple.hex"
mkdir "$build/bypass-attiny202-cd4053_simple.hex"
if output=$(run_build 2>&1); then
	printf 'FAIL: unremovable stale output was accepted\n' >&2
	exit 1
fi
[[ "$output" == *"could not remove stale ATtiny202 artifacts"* ]] \
	|| { printf 'FAIL: stale-directory cleanup failed for the wrong reason: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

printf 'ATtiny202 build validation: %d checks, 0 failures\n' "$checks"
