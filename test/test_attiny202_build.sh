#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-attiny202-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
dfp="$work/dfp"
build="$work/build"
mkdir -p "$tools" "$dfp/gcc/dev/attiny202/device-specs" "$dfp/include/avr"
: > "$dfp/gcc/dev/attiny202/device-specs/specs-attiny202"
: > "$dfp/include/avr/iotn202.h"
checks=0
unset FAKE_CC_MODE FAKE_READELF_MODE FAKE_SIZE_MODE FAKE_OBJCOPY_MODE
unset TEST_VARIANTS TEST_DFP XT_FLASH_BYTES
# The skip-policy checks below pin STRICT_TOOLS explicitly; clear any ambient
# value (scripts/ci-local.sh exports STRICT_TOOLS=1) so nothing inherits it.
unset STRICT_TOOLS

cat > "$tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake avr-gcc 1\n'; exit 0; fi
out=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
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
	malformed) printf 'Program: nope bytes\n' ;;
	over) printf 'Program: 4096 bytes\n' ;;
	huge) printf 'Program: 999999999999999999999999999999999999 bytes\n' ;;
	adjacent) printf 'Program: 999999999999999999999999999999999999 bytes\n' ;;
	*) printf 'Program: 100 bytes\n' ;;
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
		XT_BUILD_DIR="$build" XT_DFP="${TEST_DFP-$dfp}" VARIANTS="${TEST_VARIANTS-cd4053}" \
		CC="$tools/cc" READELF="$tools/readelf" SIZE="$tools/size" \
		OBJCOPY="$tools/objcopy" "$@"
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

seed_stale
(export TEST_VARIANTS="cd4053 mute relay"; run_build) >/dev/null
# Spelled out per variant rather than composed from the variant name: the
# canonical basename's stage token is NOT the variant token (`mute` builds
# `cd4053_with_mute`), and this test's job includes proving the build emits the
# names the release contract names.
for spec in "cd4053 cd4053_simple" "mute cd4053_with_mute" "relay tq2_l2_5v_relay"; do
	read -r variant stage <<<"$spec"
	stem="$build/bypass-attiny202-${stage}"
	[ -s "$stem.elf" ] \
		|| { printf 'FAIL: missing fresh %s ELF\n' "$variant" >&2; exit 1; }
	grep -q '^fresh ELF$' "$stem.elf" \
		|| { printf 'FAIL: stale %s ELF survived\n' "$variant" >&2; exit 1; }
	grep -q '^:0100000001FE$' "$stem.hex" \
		|| { printf 'FAIL: stale %s HEX survived\n' "$variant" >&2; exit 1; }
	grep -Eq '^:00000001[Ff][Ff]\r?$' "$stem.hex" \
		|| { printf 'FAIL: missing fresh valid %s HEX\n' "$variant" >&2; exit 1; }
	checks=$((checks + 1))
done

expect_failure "compiler failure" "did not compile" FAKE_CC_MODE=fail
expect_failure "empty compiler output" "produced no ELF" FAKE_CC_MODE=empty
expect_failure "readelf failure" "could not inspect ELF" FAKE_READELF_MODE=fail
expect_failure "wrong architecture" "is not avrxmega3" FAKE_READELF_MODE=wrong
expect_failure "size command failure" "could not measure Program size" FAKE_SIZE_MODE=fail
expect_failure "missing size output" "invalid Program size" FAKE_SIZE_MODE=empty
expect_failure "malformed size output" "invalid Program size" FAKE_SIZE_MODE=malformed
expect_failure "flash budget overflow" "exceeds 2048 B" FAKE_SIZE_MODE=over
expect_failure "huge size overflow" "exceeds 2048 B" FAKE_SIZE_MODE=huge
expect_failure "adjacent huge size overflow" "exceeds 999999999999999999999999999999999998 B" \
	FAKE_SIZE_MODE=adjacent XT_FLASH_BYTES=999999999999999999999999999999999998
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
expect_failure "unsupported variant" "unsupported ATtiny202 variant" TEST_VARIANTS=bogus
expect_failure "redirect-like variant" "unsupported ATtiny202 variant" \
	"TEST_VARIANTS=cd4053 >$work/injected"
[ ! -e "$work/injected" ] || { printf 'FAIL: variant text executed a redirection\n' >&2; exit 1; }
expect_failure "duplicate variant" "duplicate ATtiny202 variant" \
	"TEST_VARIANTS=cd4053 cd4053"
expect_failure "empty variant matrix" "VARIANTS is empty" TEST_VARIANTS=

seed_stale
if output=$(run_build VARIANTS=bogus XT_VARIANTS_UNKNOWN= \
		XT_VARIANTS_REQUESTED=cd4053 2>&1); then
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
