#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/test/check_flash_budget.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-flash-budget.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
images="$work/images"
mkdir -p "$tools" "$images"
checks=0
unset FAKE_SIZE_MODE FAKE_SIZE_FAIL_NAME TEST_SIZE_COMMAND TEST_FLASH_BYTES TEST_BUDGET
unset FLASH_T13_BUDGET MAKEFLAGS MFLAGS GNUMAKEFLAGS

cat > "$tools/size" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do elf=$arg; done
if [ -n "${FAKE_SIZE_FAIL_NAME:-}" ] && [ "${elf##*/}" = "$FAKE_SIZE_FAIL_NAME" ]; then
	printf 'selected size failure\n' >&2
	exit 1
fi
case "${FAKE_SIZE_MODE:-pass}" in
	fail) printf 'size failed\n' >&2; exit 1 ;;
	empty) exit 0 ;;
	malformed) printf 'Program: unknown bytes (0.0%% Full)\n' ;;
	trailing) printf 'Program: 512 bytes (50.0%% Full) garbage\n' ;;
	duplicate) printf 'Program: 512 bytes (50.0%% Full)\nProgram: 512 bytes (50.0%% Full)\n' ;;
	zero) printf 'Program: 0 bytes (0.0%% Full)\n' ;;
	tiny) printf 'Program: 10 bytes (1.0%% Full)\n' ;;
	boundary) printf 'Program: 921 bytes (89.9%% Full)\n' ;;
	over) printf 'Program: 922 bytes (90.0%% Full)\n' ;;
	huge) printf 'Program: 999999999999999999999999999999 bytes (100.0%% Full)\n' ;;
	max) printf 'Program: 4294967295 bytes (100.0%% Full)\n' ;;
	adjacent) printf 'Program: 4000000001 bytes (100.0%% Full)\n' ;;
	*) printf 'AVR Memory Usage\nProgram: 512 bytes (50.0%% Full)\nData: 8 bytes\n' ;;
esac
EOF

cat > "$tools/wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
chmod 750 "$tools/size" "$tools/wrapper"

reset_images() {
	rm -rf "$images"
	mkdir -p "$images"
	printf 'test\n' > "$work/toolchain.stamp"
	for name in cd4053 mute relay; do printf 'ELF %s\n' "$name" > "$images/bypass_$name.elf"; done
}

run_check() {
	"$CHECK" "${TEST_SIZE_COMMAND-$tools/size}" attiny13a \
		"${TEST_FLASH_BYTES-1024}" "${TEST_BUDGET-90}" 3 \
		"$images/bypass_cd4053.elf" "$images/bypass_mute.elf" "$images/bypass_relay.elf"
}

run_make_gate() {
	make --no-print-directory -C "$ROOT" test-flash-budget \
		AVR_BUILD_DIR="$images" SIZE="$tools/size" \
		TOOLCHAIN_STAMP="$work/toolchain.stamp" TOOLCHAIN_SIG=test \
		FLASH_T13_BUDGET=90 VARIANTS="cd4053 mute relay" \
		MCU=attiny13a FW_BASE=bypass "$@"
}

expect_pass() {
	local label=$1 output
	shift
	reset_images
	output=$(export "$@"; run_check) \
		|| { printf 'FAIL: %s was rejected\n' "$label" >&2; exit 1; }
	[[ "$output" == *"OK: measured all 3 firmware images"* ]] \
		|| { printf 'FAIL: %s lacked the complete verdict\n' "$label" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_failure() {
	local label=$1 expected=$2 output
	shift 2
	reset_images
	if output=$(export "$@"; run_check 2>&1); then
		printf 'FAIL: %s was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$expected"* ]] \
		|| { printf 'FAIL: %s failed for the wrong reason: %s\n' "$label" "$output" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_pass "valid measurements"
expect_pass "compound size command" "TEST_SIZE_COMMAND=$tools/wrapper $tools/size"
expect_pass "exact budget boundary" FAKE_SIZE_MODE=boundary
expect_pass "one-percent boundary" FAKE_SIZE_MODE=tiny TEST_BUDGET=1
expect_pass "full-budget endpoint" TEST_BUDGET=100
expect_pass "UINT32 maximum" FAKE_SIZE_MODE=max TEST_FLASH_BYTES=4294967295 TEST_BUDGET=100
expect_failure "size command failure" "size command failed" FAKE_SIZE_MODE=fail
expect_failure "one-image size failure" "size command failed for $images/bypass_mute.elf" \
	FAKE_SIZE_FAIL_NAME=bypass_mute.elf
expect_failure "missing size output" "expected one Program size" FAKE_SIZE_MODE=empty
expect_failure "malformed size output" "malformed Program size" FAKE_SIZE_MODE=malformed
expect_failure "trailing size output" "malformed Program size" FAKE_SIZE_MODE=trailing
expect_failure "duplicate size output" "expected one Program size" FAKE_SIZE_MODE=duplicate
expect_failure "zero size" "must be greater than zero" FAKE_SIZE_MODE=zero
expect_failure "over budget" "exceeds 921 B" FAKE_SIZE_MODE=over
expect_failure "huge size" "exceeds 921 B" FAKE_SIZE_MODE=huge
expect_failure "adjacent large size" "exceeds 4000000000 B" \
	FAKE_SIZE_MODE=adjacent TEST_FLASH_BYTES=4000000000 TEST_BUDGET=100
expect_failure "zero flash bytes" "flash byte count" TEST_FLASH_BYTES=0
expect_failure "huge flash bytes" "flash byte count" TEST_FLASH_BYTES=4294967296
expect_failure "zero budget" "percentage" TEST_BUDGET=0
expect_failure "oversized budget" "percentage" TEST_BUDGET=101
expect_failure "malformed budget" "percentage" TEST_BUDGET=invalid

reset_images
rm "$images/bypass_mute.elf"
if output=$(run_check 2>&1); then printf 'FAIL: missing ELF was accepted\n' >&2; exit 1; fi
[[ "$output" == *"missing, empty, or not a regular file"* ]] \
	|| { printf 'FAIL: missing ELF failed for the wrong reason: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

reset_images
rm "$images/bypass_mute.elf"
ln -s bypass_cd4053.elf "$images/bypass_mute.elf"
if output=$(run_check 2>&1); then printf 'FAIL: symlink ELF was accepted\n' >&2; exit 1; fi
[[ "$output" == *"missing, empty, or not a regular file"* ]] \
	|| { printf 'FAIL: symlink ELF failed for the wrong reason: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

reset_images
: > "$images/bypass_mute.elf"
if output=$(run_check 2>&1); then printf 'FAIL: empty ELF was accepted\n' >&2; exit 1; fi
[[ "$output" == *"missing, empty, or not a regular file"* ]] \
	|| { printf 'FAIL: empty ELF failed for the wrong reason: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

reset_images
output=$(run_make_gate)
[[ "$output" == *"OK: measured all 3 firmware images"* ]] \
	|| { printf 'FAIL: Make flash gate lacked complete verdict\n' >&2; exit 1; }
checks=$((checks + 1))

for override in MCU=attiny85 FW_BASE=alternate AVR_FW=alternate; do
	reset_images
	before=$(sha256sum "$images"/*.elf)
	if output=$(run_make_gate "$override" 2>&1); then
		printf 'FAIL: Make override %s bypassed the ATtiny13a gate\n' "$override" >&2
		exit 1
	fi
	[[ "$output" == *"requires MCU=attiny13a, FW_BASE=bypass"* ]] \
		|| { printf 'FAIL: Make override %s failed for the wrong reason: %s\n' "$override" "$output" >&2; exit 1; }
	after=$(sha256sum "$images"/*.elf)
	[[ "$after" == "$before" ]] \
		|| { printf 'FAIL: rejected Make override %s modified firmware images\n' "$override" >&2; exit 1; }
	checks=$((checks + 1))
done

for variants in '' 'cd4053' 'cd4053 mute' 'cd4053 mute relay relay' \
	'cd4053 mute bogus'; do
	reset_images
	before=$(sha256sum "$images"/*.elf)
	if output=$(run_make_gate "VARIANTS=$variants" 2>&1); then
		printf 'FAIL: incomplete Make variant matrix %q was accepted\n' "$variants" >&2
		exit 1
	fi
	[[ "$output" == *"requires the complete cd4053/mute/relay variant matrix"* ]] \
		|| { printf 'FAIL: matrix %q failed for the wrong reason: %s\n' "$variants" "$output" >&2; exit 1; }
	after=$(sha256sum "$images"/*.elf)
	[[ "$after" == "$before" ]] \
		|| { printf 'FAIL: rejected matrix %q modified firmware images\n' "$variants" >&2; exit 1; }
	checks=$((checks + 1))
done

for overrides in 'FLASH_T13_ELFS=alternate.elf' \
	'FLASH_T13_MCU=attiny85 FLASH_T13_BYTES=1'; do
	reset_images
	read -r -a override_args <<<"$overrides"
	output=$(run_make_gate "${override_args[@]}") \
		|| { printf 'FAIL: internal override protection rejected valid gate\n' >&2; exit 1; }
	[[ "$output" == *"OK: measured all 3 firmware images"* ]] \
		|| { printf 'FAIL: internal overrides changed the gate: %s\n' "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

reset_images
if output=$("$CHECK" "$tools/size" attiny13a 1024 90 3 \
		"$images/bypass_cd4053.elf" 2>&1); then
	printf 'FAIL: incomplete explicit image set was accepted\n' >&2
	exit 1
fi
[[ "$output" == *"expected 3 firmware images, received 1"* ]] \
	|| { printf 'FAIL: incomplete set failed for the wrong reason: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

printf 'flash-budget gate validation: %d checks, 0 failures\n' "$checks"
