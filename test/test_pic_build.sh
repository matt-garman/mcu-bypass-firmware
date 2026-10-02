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

# Host-only fake-XC8 regression for PIC image generation on all three parts.
#   - Missing, partial, malformed, symlinked or interrupted XC8 output cannot
#     become an image.
#   - Malformed budgets, impossible usage counts and failed arithmetic tools
#     are rejected.
#   - A skip removes the complete product matrix, and each part's producer
#     publishes an immutable complete matrix.
#   - Stale assembly/symbol sidecars cannot outlive a HEX-only rebuild.
#   - The PIC10F320 image and host rebuild triggers hold.
# Make requests every part's profile by name, and the script rejects a missing,
# duplicate or unknown one.
#
# THE DEFECT. Before d15cc7e (2026-07-13) an XC8 image was not validated as
# Intel HEX before its flash usage was accepted, and a failure could leave part
# of the requested matrix behind. These are the images programmed into a
# device.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly -a PB_REQUIRED_PROFILES=(pic10f322 pic10f320 pic12f675)
readonly -a PB_CANONICAL_VARIANTS=(
	cd4053_simple
	cd4053_with_mute
	tq2_l2_5v_relay
)

pb_validate_profile_request() {
	local name required
	local -a missing=()
	local -A known=() seen=()
	[ "$#" -gt 0 ] \
		|| { printf 'FAIL: PIC build profile request must not be empty\n' >&2; return 2; }
	for required in "${PB_REQUIRED_PROFILES[@]}"; do known[$required]=1; done
	for name in "$@"; do
		[ -n "$name" ] \
			|| { printf 'FAIL: PIC build profile request contains an empty name\n' >&2; return 2; }
		[ -n "${known[$name]+yes}" ] \
			|| { printf 'FAIL: PIC build profile request contains unknown name: %s\n' "$name" >&2; return 2; }
		[ -z "${seen[$name]+yes}" ] \
			|| { printf 'FAIL: PIC build profile request contains duplicate name: %s\n' "$name" >&2; return 2; }
		seen[$name]=1
	done
	for required in "${PB_REQUIRED_PROFILES[@]}"; do
		[ -n "${seen[$required]+yes}" ] || missing+=("$required")
	done
	[ "${#missing[@]}" -eq 0 ] \
		|| { printf 'FAIL: PIC build profile request is incomplete; missing: %s\n' \
			"${missing[*]}" >&2; return 2; }
}

pb_expect_profile_reject() {
	local label=$1
	shift
	if pb_validate_profile_request "$@" >/dev/null 2>&1; then
		printf 'FAIL: PIC build profile validator accepted %s request\n' "$label" >&2
		exit 1
	fi
}

if [ "${1:-}" != --run-profile ]; then
	pb_validate_profile_request "$@" || exit
	pb_expect_profile_reject empty
	pb_expect_profile_reject explicit-empty "${PB_REQUIRED_PROFILES[@]}" ""
	pb_expect_profile_reject unknown "${PB_REQUIRED_PROFILES[@]}" unknown
	pb_expect_profile_reject duplicate "${PB_REQUIRED_PROFILES[@]}" pic10f320
	pb_expect_profile_reject incomplete pic10f322 pic10f320
	for profile in "${PB_REQUIRED_PROFILES[@]}"; do
		"$0" --run-profile "$profile"
	done
	printf 'PIC build profile request validation: 5 checks, 0 failures\n'
	exit 0
fi

[ "$#" -eq 2 ] && [ -n "$2" ] \
	|| { printf 'FAIL: internal PIC build profile worker request is malformed\n' >&2; exit 2; }
readonly PB_PROFILE=$2

PB_FW_BASE_VAR=FW_BASE
PB_FW_BASE=bypass
PB_VARIANT=cd4053_simple
PB_MATRIX_VARIANTS="${PB_CANONICAL_VARIANTS[*]}"
PB_MATRIX_REQUIRE_COMPLETE=1
PB_SELECTOR_ROUTING=0
PB_SIZE_TARGET=
PB_RETURN_STACK_REQUIRED=0
PB_REBUILD_REQUIRED=0
matrix_supported_var=
product_override_args=()
case "$PB_PROFILE" in
	pic10f322)
		PB_LABEL=PIC
		PB_TARGET=pic10f322
		PB_CC_VAR=PIC_CC
		PB_BUILD_DIR_VAR=PIC10F322_BUILD_DIR
		PB_BUILD_DIR=build_pic10f322
		PB_TAG_VAR=PIC10F322_TAG
		PB_TAG=pic10f322
		PB_FLASH_VAR=PIC10F322_FLASH_WORDS
		PB_FLASH_WORDS=512
		PB_VARIANT_VAR=VARIANTS
		PB_BUILD_VARIANTS=$PB_MATRIX_VARIANTS
		PB_MATRIX_TARGET=pic10f322
		PB_MATRIX_VARIANTS_VAR=VARIANTS
		PB_MATRIX_UNSUPPORTED=unknown
		PB_STACK_TARGET=pic10f322-test-stack-bound
		PB_STACK_DEVICE_VAR=PIC10F322_DEVICE_INI
		product_override_args=(PIC10F322_HEXES= PIC10F322_ASSEMBLIES= PIC10F322_SYMBOLS= PIC10F322_BUILD_PRODUCTS=)
		matrix_supported_var=CLASSIC_VARIANTS_SUPPORTED
		expected_checks=48
		;;
	pic10f320)
		PB_LABEL=PIC10F320
		PB_TARGET=pic10f320
		PB_CC_VAR=PIC10F320_CC
		PB_BUILD_DIR_VAR=PIC10F320_BUILD_DIR
		PB_BUILD_DIR=build_pic10f320
		PB_TAG_VAR=PIC10F320_TAG
		PB_TAG=pic10f320
		PB_FLASH_VAR=PIC10F320_FLASH_WORDS
		PB_FLASH_WORDS=256
		PB_VARIANT_VAR=PIC10F320_VARIANT
		PB_BUILD_VARIANTS=$PB_VARIANT
		PB_MATRIX_TARGET=pic10f320-variants
		PB_MATRIX_VARIANTS_VAR=PIC10F320_VARIANTS_ALL
		PB_MATRIX_UNSUPPORTED=tmux4053-simple
		PB_STACK_TARGET=pic10f320-test-stack-bound
		PB_STACK_DEVICE_VAR=PIC10F320_DEVICE_INI
		PB_RETURN_STACK_REQUIRED=1
		PB_SELECTOR_ROUTING=1
		PB_SIZE_TARGET=pic10f320-size
		PB_REBUILD_REQUIRED=1
		product_override_args=(PIC10F320_HEX= PIC10F320_ASM= PIC10F320_SYM= PIC10F320_BUILD_PRODUCTS=)
		expected_checks=102
		;;
	pic12f675)
		PB_LABEL=PIC12F675
		PB_TARGET=pic12f675
		PB_CC_VAR=PIC_CC
		PB_BUILD_DIR_VAR=PIC12F675_BUILD_DIR
		PB_BUILD_DIR=build_pic12f675
		PB_TAG_VAR=PIC12F675_TAG
		PB_TAG=pic12f675
		PB_FLASH_VAR=PIC12F675_FLASH_WORDS
		PB_FLASH_WORDS=1024
		PB_VARIANT_VAR=VARIANTS
		PB_BUILD_VARIANTS=$PB_MATRIX_VARIANTS
		PB_MATRIX_TARGET=pic12f675
		PB_MATRIX_VARIANTS_VAR=VARIANTS
		PB_MATRIX_UNSUPPORTED=unknown
		PB_STACK_TARGET=pic12f675-test-stack-bound
		PB_STACK_DEVICE_VAR=PIC12F675_DEVICE_INI
		product_override_args=(PIC12F675_HEXES= PIC12F675_ASSEMBLIES= PIC12F675_SYMBOLS= PIC12F675_BUILD_PRODUCTS=)
		matrix_supported_var=CLASSIC_VARIANTS_SUPPORTED
		expected_checks=101
		;;
	*) printf 'FAIL: unknown internal PIC build profile: %s\n' "$PB_PROFILE" >&2; exit 2 ;;
esac
PB_MATRIX_IMAGES=
for variant in "${PB_CANONICAL_VARIANTS[@]}"; do
	PB_MATRIX_IMAGES+="${PB_MATRIX_IMAGES:+ }${PB_FW_BASE}-${PB_TAG}-${variant}.hex"
done
PB_MATRIX_FAIL_IMAGE="${PB_FW_BASE}-${PB_TAG}-${PB_CANONICAL_VARIANTS[2]}.hex"
for value in "$PB_LABEL" "$PB_TARGET" "$PB_CC_VAR" "$PB_BUILD_DIR_VAR" \
		"$PB_BUILD_DIR" "$PB_FW_BASE_VAR" "$PB_FW_BASE" "$PB_TAG_VAR" \
		"$PB_TAG" "$PB_FLASH_VAR" "$PB_FLASH_WORDS" "$PB_VARIANT_VAR" \
		"$PB_VARIANT" "$PB_BUILD_VARIANTS" "$PB_MATRIX_TARGET" \
		"$PB_MATRIX_VARIANTS_VAR" "$PB_MATRIX_VARIANTS" "$PB_MATRIX_IMAGES" \
		"$PB_MATRIX_FAIL_IMAGE" "$PB_MATRIX_UNSUPPORTED" "$PB_STACK_TARGET" \
		"$PB_STACK_DEVICE_VAR" "$expected_checks"; do
	[ -n "$value" ] || { printf 'FAIL: incomplete internal PIC build profile: %s\n' "$PB_PROFILE" >&2; exit 2; }
done
for value in "$PB_MATRIX_REQUIRE_COMPLETE" "$PB_SELECTOR_ROUTING" \
		"$PB_RETURN_STACK_REQUIRED" "$PB_REBUILD_REQUIRED"; do
	[[ "$value" =~ ^[01]$ ]] \
		|| { printf 'FAIL: invalid boolean in PIC build profile: %s\n' "$PB_PROFILE" >&2; exit 2; }
done
[ "${#product_override_args[@]}" -eq 4 ] \
	|| { printf 'FAIL: incomplete product overrides in PIC build profile: %s\n' "$PB_PROFILE" >&2; exit 2; }

real_make=$(command -v make)
test_temp_root=${TMPDIR:-${XDG_RUNTIME_DIR:-${HOME:?HOME is required when TMPDIR and XDG_RUNTIME_DIR are unset}}}
work=$(mktemp -d -- "$test_temp_root/test-pic-build.XXXXXX")
cleanup_work() {
	chmod -R u+w "$work" 2>/dev/null || :
	rm -rf "$work"
}
trap cleanup_work EXIT
repo="$work/repo"
tools="$work/tools"
xc8_log="$work/xc8.log"
host_cc_log="$work/host-cc.log"
host_run_log="$work/host-run.log"
target_cc_log="$work/target-cc.log"
gpsim_inc="$work/gpsim"
# Local restatement of the Makefile's canonical image basename (see its
# "canonical firmware image basename" block): <prefix>-<mcu>-<output stage>,
# where the stage field is the variant name itself. Deliberately independent of
# the Makefile rather than read back from it -- this regression exists to prove
# the build emits the names the release contract expects, and a name derived
# from the thing under test could not fail.
pb_image() {
	printf '%s/%s/%s-%s-%s.hex' "$repo" "$PB_BUILD_DIR" \
		"$PB_FW_BASE" "$PB_TAG" "$1"
}
hex=$(pb_image "$PB_VARIANT")
asm=${hex%.hex}.s
sym=${hex%.hex}.sym
size_probe_stem="$repo/$PB_BUILD_DIR/size_probe_$PB_VARIANT"
checks=0
unset FAKE_XC8_MODE FAKE_XC8_FAIL_NAME FAKE_XC8_SIGNAL_MARKER \
	FAKE_XC8_PROGRAM_MODE FAKE_XC8_PROGRAM_FAIL_NAME \
	FAKE_XC8_DATA_MODE FAKE_XC8_DATA_FAIL_NAME \
	MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
mkdir -p "$repo/src" "$repo/scripts" "$repo/test/pic10f320/equiv" \
	"$repo/test/pic10f320/actuation" "$repo/test/pic10f320/fault" \
	"$repo/test/pic10f320/gpsim" "$repo/test/pic" \
	"$repo/build_pic10f322" "$tools" "$gpsim_inc"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$repo/scripts/validate-ihex.sh"
cp "$ROOT/test/check_stack_depth_pic.sh" "$repo/test/check_stack_depth_pic.sh"
cp "$ROOT/test/check_pic_data_budget.sh" "$repo/test/check_pic_data_budget.sh"
cp "$ROOT/test/parse_xc8_program_space.sh" "$repo/test/parse_xc8_program_space.sh"
cp "$ROOT/test/check_pic_context_layout.sh" "$repo/test/check_pic_context_layout.sh"
cp "$ROOT/test/pic10f320/return_stack_oracle.py" \
	"$repo/test/pic10f320/return_stack_oracle.py"
cp "$ROOT/test/pic10f320/check_expected_images.py" \
	"$repo/test/pic10f320/check_expected_images.py"
: > "$xc8_log"
: > "$host_cc_log"
: > "$host_run_log"
: > "$target_cc_log"
: > "$gpsim_inc/sim_context.h"
export FAKE_XC8_LOG="$xc8_log"
export FAKE_XC8_PROGRAM_CAPACITY="$PB_FLASH_WORDS"
# The over-budget fixture must be over THIS lane's budget, not a fixed 513: a
# 513-word image is comfortably inside a 1024-word part, so a hard-coded value
# silently stopped testing the budget gate the moment a bigger part arrived.
# One word past is also a sharper test than "far over" -- it pins the boundary.
export FAKE_XC8_OVER_BUDGET_WORDS=$((PB_FLASH_WORDS + 1))

cat > "$tools/xc8" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
write_valid_hex() {
	case "${out:-}" in
		*-cd4053_with_mute.hex) program_record=:040000000100FF23D9 ;;
		*-tq2_l2_5v_relay.hex) program_record=:040000000200FF23D8 ;;
		*) program_record=:040000000000FF23DA ;;
	esac
	case "${FAKE_XC8_PIC12F675_MODE:-default}" in
		shipping)
			printf '%s\n' "$program_record" ':02400E00CC31B3' ':00000001FF'
			;;
		*)
			printf '%s\n' ':020000000028D6' ':02400E009E38DA' ':00000001FF'
			;;
	esac
}
write_bad_stack_hex() {
	# Structurally valid PIC14 image whose reset instruction is RETFIE (0x0009).
	printf '%s\n' \
		':020000000900F5' \
		':02400E009E38DA' \
		':00000001FF'
}
write_bad_depth_hex() {
	# Precomputed classic-PIC14 chain: CALLs at words 0,2,...,16 reach depth 9.
	printf '%s\n' \
		':10000000022001280420080006200800082008001B' \
		':100010000A2008000C2008000E200800102008000C' \
		':0600200012200800080098' \
		':00000001FF'
}
write_hash_mismatch_hex() {
	# Structurally valid, safe PIC14 image with different bytes from write_valid_hex.
	printf '%s\n' \
		':0400000001280128AA' \
		':02400E009E38DA' \
		':00000001FF'
}
write_sidecars() {
	cat > "${out%.hex}.s" <<'ASM'
;; *************** function _main *****************
;; This function is called by:
;;	Startup code after reset
;; This function calls:
;;	Nothing

__ptext_main:	;psect for function _main
	return
	callstack 8
_ctx_:
	ds 3
ASM
	# Real XC8 .sym shape: a global symbol table of
	# "<name> <address> <end> <class> <bank>" records, then the %segments and
	# %locals sections. The context checker parses this file, so the stub has
	# to emit the format the linker emits.
	printf '%s\n' \
		'_main 188 0 CODE 0' \
		'_ctx_ 5D 0 BANK0 1' \
		'%segments' \
		'cstackBANK0 40 63 BANK0 40 1' \
		'%locals' > "${out%.hex}.sym"
}
write_data_summary() {
	local data_mode=${FAKE_XC8_DATA_MODE:-pass}
	if [ -n "${FAKE_XC8_DATA_FAIL_NAME:-}" ] \
			&& [ "$out" = "$FAKE_XC8_DATA_FAIL_NAME" ]; then
		data_mode=over-limit
	fi
	case "$data_mode" in
		missing) ;;
		duplicate)
			printf '%s\n' \
				'Data space used 20h (32) of 40h bytes (50.0%)' \
				'Data space used 20h (32) of 40h bytes (50.0%)'
			;;
		malformed) printf 'Data space used 20h 32 of 40h bytes (50.0%%)\n' ;;
		bad-percent) printf 'Data space used 20h (32) of 40h bytes (50.%%)\n' ;;
		percent-mismatch) printf 'Data space used 20h (32) of 40h bytes (99.9%%)\n' ;;
		mixed-malformed)
			printf '%s\n' \
				'Data space used 20h (32) of 40h bytes (50.0%)' \
				'Data   space used 20h (32) of 40h bytes (50.0%) trailing'
			;;
		trailing) printf 'Data space used 20h (32) of 40h bytes (50.0%%) trailing\n' ;;
		wrong-unit) printf 'Data space used 20h (32) of 40h words (50.0%%)\n' ;;
		zero) printf 'Data space used 0h (0) of 40h bytes (0.0%%)\n' ;;
		over-limit) printf 'Data space used 31h (49) of 40h bytes (76.6%%)\n' ;;
		huge)
			printf 'Data space used 9999999999999999999999999999999999999999h (9999999999999999999999999999999999999999) of 40h bytes (9999999999999999999999999999999999999999%%)\n'
			;;
		used-mismatch) printf 'Data space used 20h (33) of 40h bytes (51.6%%)\n' ;;
		capacity-hex) printf 'Data space used 20h (32) of 41h bytes (49.2%%)\n' ;;
		boundary) printf 'Data space used 30h (48) of 40h bytes (75.0%%)\n' ;;
		xc8-tie) printf 'Data space used 24h (36) of 40h bytes (56.2%%)\n' ;;
		spaced) printf '  Data   space used 020h ( 0032 ) of 040h bytes ( 050.0 %% )  \n' ;;
		*)
			case "$out" in
				*-cd4053_with_mute.hex) printf 'Data space used 21h (33) of 40h bytes (51.6%%)\n' ;;
				*-tq2_l2_5v_relay.hex) printf 'Data space used 22h (34) of 40h bytes (53.1%%)\n' ;;
				*) printf 'Data space used 20h (32) of 40h bytes (50.0%%)\n' ;;
			esac
			;;
	esac
}
out=
args=$*
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
printf '%s\t%s\n' "$out" "$args" >> "${FAKE_XC8_LOG:?}"
mode=${FAKE_XC8_MODE:-pass}
program_mode=${FAKE_XC8_PROGRAM_MODE:-$mode}
if [ -n "${FAKE_XC8_PROGRAM_FAIL_NAME:-}" ] \
		&& [ "$out" = "$FAKE_XC8_PROGRAM_FAIL_NAME" ]; then
	program_mode=program-malformed
fi
write_program_record() {
	local decimal_text=$1 decimal_value=$2 capacity=${FAKE_XC8_PROGRAM_CAPACITY:?}
	local used_hex capacity_hex percent
	printf -v used_hex '%X' "$decimal_value"
	printf -v capacity_hex '%X' "$capacity"
	percent=$(awk -v used="$decimal_value" -v total="$capacity" \
		'BEGIN { printf "%.1f", used * 100 / total }')
	printf 'Program space used %sh (%s) of %sh words (%s%%)\n' \
		"$used_hex" "$decimal_text" "$capacity_hex" "$percent"
}
case "$program_mode" in
	no-summary) ;;
	over-budget)
		words=${FAKE_XC8_OVER_BUDGET_WORDS:-513}
		write_program_record "$words" "$words"
		;;
	huge-count)
		printf 'Program space used FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFh (9999999999999999999999999999999999999999) of %Xh words (999.9%%)\n' \
			"${FAKE_XC8_PROGRAM_CAPACITY:?}"
		;;
	leading-count) write_program_record 00042 42 ;;
	program-malformed) printf 'Program space used (42)\n' ;;
	program-duplicate)
		write_program_record 42 42
		write_program_record 42 42
		;;
	program-mixed)
		write_program_record 42 42
		printf 'Program space used garbage\n'
		;;
	program-zero) printf 'Program space used 0h (0) of %Xh words (0.0%%)\n' \
		"${FAKE_XC8_PROGRAM_CAPACITY:?}" ;;
	program-percent) printf 'Program space used 2Ah (42) of %Xh words (99.9%%)\n' \
		"${FAKE_XC8_PROGRAM_CAPACITY:?}" ;;
	*) write_program_record 42 42 ;;
esac
write_data_summary
if [ -n "${FAKE_XC8_FAIL_NAME:-}" ] && [ "$out" = "$FAKE_XC8_FAIL_NAME" ]; then
	mode=fail
fi
case "$mode" in
	missing|no-sidecars) ;;
	*) write_sidecars ;;
esac
case "$mode" in
	fail) printf 'partial image\n' > "$out"; exit 1 ;;
	missing) : ;;
	no-sidecars) write_valid_hex > "$out" ;;
	empty) : > "$out" ;;
	signal)
		write_valid_hex > "$out"
		builtin kill -TERM "${PIC_RECIPE_PID:?}"
		if [ -n "${FAKE_XC8_SIGNAL_MARKER:-}" ]; then
			printf 'delivered\n' > "$FAKE_XC8_SIGNAL_MARKER"
		fi
		sleep 1
		;;
	bad-checksum) printf ':0100000001FF\n:00000001FF\n' > "$out" ;;
	bad-stack) write_bad_stack_hex > "$out" ;;
	bad-depth) write_bad_depth_hex > "$out" ;;
	hash-mismatch) write_hash_mismatch_hex > "$out" ;;
	nondeterministic-private)
		if [[ "$PWD" == *.qualify.* && "$out" == *-cd4053_simple.hex ]]; then
			write_hash_mismatch_hex > "$out"
		else
			write_valid_hex > "$out"
		fi
		;;
	eof-only) printf ':00000001FF\n' > "$out" ;;
	trailing) printf ':0100000001FE\n:00000001FF\ntrailing garbage\n' > "$out" ;;
	symlink)
		write_valid_hex > valid.hex
		ln -s valid.hex "$out"
		;;
	directory) mkdir "$out" ;;
	*) write_valid_hex > "$out" ;;
esac
case "$out" in
	size_probe_*.hex) printf 'temporary companion\n' > "${out%.hex}.elf" ;;
esac
EOF
cat > "$tools/host-cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=
args=$*
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
printf '%s\t%s\n' "$out" "$args" >> "${FAKE_HOST_CC_LOG:?}"
case " $args " in
	*' -c '*) printf 'nonempty fake object\n' > "$out" ;;
	*)
		cat > "$out" <<'RUNNER'
#!/usr/bin/env sh
printf '%s\n' "$0" >> "${FAKE_HOST_RUN_LOG:?}"
exit 0
RUNNER
		chmod 750 "$out"
		;;
esac
EOF
cat > "$tools/pkg-config" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
	--exists) exit 0 ;;
	--cflags) exit 0 ;;
	*) exit 2 ;;
esac
EOF
chmod 750 "$tools/xc8" "$tools/host-cc" "$repo/scripts/validate-ihex.sh"
chmod 750 "$tools/pkg-config"
cat > "$tools/noop-oracle.py" <<'EOF'
#!/usr/bin/env python3
raise SystemExit(0)
EOF
chmod 640 "$tools/noop-oracle.py"
printf '#!/usr/bin/env sh\nexit 0\n' > "$tools/noop-data-gate"
chmod 750 "$tools/noop-data-gate"

# The PIC10F320 byte-identity target must compare the fake compiler's canonical
# output with a sandbox-local baseline rather than the production XC8 hashes.
if [ "$PB_TARGET" = pic10f320 ]; then
	fake_hash=390b76d89cfb079a761cb76c4688d48e7c0b486523b9e2d5acb203d909d9b259
	for image in $PB_MATRIX_IMAGES; do
		printf '%s  %s\n' "$fake_hash" "$image"
	done > "$repo/test/pic10f320/expected_images.sha256"
fi
printf '#!/usr/bin/env sh\nexit 2\n' > "$tools/failing-awk"
printf '#!/usr/bin/env sh\nexit 0\n' > "$tools/empty-awk"
cat > "$tools/status1-comparison-awk" <<'EOF'
#!/usr/bin/env sh
case "$*" in
	*'a > b'*) exit 1 ;;
	*) printf '102.4'; exit 0 ;;
esac
EOF
cat > "$tools/invalid-comparison-awk" <<'EOF'
#!/usr/bin/env sh
case "$*" in
	*'a > b'*) printf 'invalid-result'; exit 0 ;;
	*) printf '102.4'; exit 0 ;;
esac
EOF
printf '#!/usr/bin/env sh\nprintf "8.2\\ninvalid-result"\nexit 0\n' \
	> "$tools/invalid-percentage-awk"
chmod 750 "$tools/failing-awk" "$tools/empty-awk" \
	"$tools/status1-comparison-awk" "$tools/invalid-comparison-awk" \
	"$tools/invalid-percentage-awk"

files=(
	src/bypass_mcu_pic10f322.c src/bypass_pure.c
	# src/bypass_pure.h: every part's *_HEADERS list names it (FW_HEADERS always
	# did; PIC10F322_HEADERS, PIC12F675_HEADERS and XT_HEADERS gained it in
	# e2731e9), and each list is a hard prerequisite of its image target, so an
	# absent placeholder here is "No rule to make target", not a silent skip.
	src/bypass_pure.h
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_pic10f322.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h src/bypass_output_cd4053_simple.c
	src/bypass_output_cd4053_with_mute.c src/bypass_output_tq2_l2_5v_relay.c
	src/bypass_output_cd4053_with_mute.h
	src/bypass_output_tq2_l2_5v_relay.h
	# An unlisted driver must not become a producer input merely by existing.
	src/bypass_output_unlisted.c
	# PIC10F320's shell is self-contained -- it includes no src/ header -- but
	# the `pic10f320` rule still needs its source to exist. Harmless for the
	# PIC10F322 leg, which never compiles it.
	src/bypass_mcu_pic10f320.c
	# PIC12F675 shell + pin map. Its `pic12f675` rule lists both as
	# prerequisites, so both must exist for any leg -- and an absent one is a
	# hard "No rule to make target", not a silent skip.
	src/bypass_mcu_pic12f675.c src/bypass_pins_pic12f675.h
	test/pic10f320/equiv/fw_harness.c
	test/pic10f320/equiv/test_equiv.c
	test/pic10f320/actuation/test_actuation.c
	test/pic10f320/fault/fw_fault_harness.c
	test/pic10f320/fault/test_fault.c
	test/pic10f320/gpsim/test_fault_pic.cc
	test/pic10f320/gpsim/test_io_pic.cc
	test/pic10f320/gpsim/test_lockstep_pic.cc
	test/pic/test_fault_pic_core.h
	test/pic/test_io_pic_core.h
	test/pic/test_lockstep_pic_core.h
	test/pic/target_result.h
)
for file in "${files[@]}"; do : > "$repo/$file"; done

run_make() {
	make --no-print-directory -C "$repo" "$PB_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" \
		"$PB_VARIANT_VAR=$PB_BUILD_VARIANTS" STRICT_TOOLS=1 AWK=awk "$@"
}

run_pic10f320_host_make() {
	local target=$1
	shift
	FAKE_HOST_CC_LOG="$host_cc_log" FAKE_HOST_RUN_LOG="$host_run_log" \
		make --no-print-directory -C "$repo" "$target" \
			CC=true HOSTCC=true PIC10F320_HOST_CC="$tools/host-cc" \
			PIC10F320_BUILD_DIR="$PB_BUILD_DIR" PIC10F320_VARIANT="$PB_VARIANT" "$@"
}

run_pic10f320_target_make() {
	local target=$1 selector=$2 variant=$3
	PATH="$tools:$PATH" FAKE_HOST_CC_LOG="$target_cc_log" \
		FAKE_HOST_RUN_LOG="$host_run_log" \
		make --no-print-directory -C "$repo" "$target" \
			CC=true HOSTCC="$tools/host-cc" PIC10F320_CC="$tools/xc8" \
			PIC10F320_SOAK_CXX="$tools/host-cc" \
			PIC10F320_SOAK_GPSIM_INC="$gpsim_inc" \
			PIC10F320_BUILD_DIR="$PB_BUILD_DIR" FW_BASE="$PB_FW_BASE" \
			PIC10F320_TAG="$PB_TAG" PIC10F320_FLASH_WORDS="$PB_FLASH_WORDS" \
			PIC10F320_VARIANT="$variant" "$selector=$variant" \
			STRICT_TOOLS=1 AWK=awk
}

logged_command_count() {
	local log=$1 output=$2 logged_output logged_command count=0
	while IFS=$'\t' read -r logged_output logged_command; do
		if [ "$logged_output" = "$output" ]; then count=$((count + 1)); fi
	done < "$log"
	printf '%d\n' "$count"
}

latest_logged_command() {
	local log=$1 output=$2 logged_output logged_command latest=
	while IFS=$'\t' read -r logged_output logged_command; do
		if [ "$logged_output" = "$output" ]; then latest=$logged_command; fi
	done < "$log"
	[ -n "$latest" ] || return 1
	printf '%s\n' "$latest"
}

command_has_arg() {
	case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

assert_firmware_variant_contracts() {
	local variant image command expected_macro expected_driver unexpected
	[ "$(wc -l < "$xc8_log")" -eq "${#PB_CANONICAL_VARIANTS[@]}" ] \
		|| { printf 'FAIL: %s matrix issued an unexpected number of compiler commands\n' \
			"$PB_LABEL" >&2; exit 1; }
	for variant in "${PB_CANONICAL_VARIANTS[@]}"; do
		image="$PB_FW_BASE-$PB_TAG-$variant.hex"
		[ "$(logged_command_count "$xc8_log" "$image")" -eq 1 ] \
			|| { printf 'FAIL: %s matrix did not compile %s exactly once\n' \
				"$PB_LABEL" "$image" >&2; exit 1; }
		command=$(latest_logged_command "$xc8_log" "$image")
		case "$PB_PROFILE:$variant" in
			pic10f320:cd4053_simple) expected_macro=OUTPUT_CD4053_SIMPLE ;;
			pic10f320:cd4053_with_mute) expected_macro=OUTPUT_CD4053_WITH_MUTE ;;
			pic10f320:tq2_l2_5v_relay) expected_macro=OUTPUT_TQ2_RELAY ;;
			*:cd4053_simple)
				expected_macro=CD4053_SIMPLE
				expected_driver="$repo/src/bypass_output_cd4053_simple.c"
				;;
			*:cd4053_with_mute)
				expected_macro=CD4053_WITH_MUTE
				expected_driver="$repo/src/bypass_output_cd4053_with_mute.c"
				;;
			*:tq2_l2_5v_relay)
				expected_macro=TQ2_L2_5V_RELAY
				expected_driver="$repo/src/bypass_output_tq2_l2_5v_relay.c"
				;;
		esac
		command_has_arg "$command" "-D$expected_macro" \
			|| { printf 'FAIL: %s compiler used the wrong selector for %s\n' \
				"$PB_LABEL" "$variant" >&2; exit 1; }
		if [ "$PB_PROFILE" = pic10f320 ]; then
			for unexpected in OUTPUT_CD4053_SIMPLE OUTPUT_CD4053_WITH_MUTE OUTPUT_TQ2_RELAY; do
				if [ "$unexpected" != "$expected_macro" ] \
						&& command_has_arg "$command" "-D$unexpected"; then
					printf 'FAIL: PIC10F320 compiler mixed selectors for %s\n' "$variant" >&2
					exit 1
				fi
			done
			command_has_arg "$command" "$repo/src/bypass_mcu_pic10f320.c" \
				|| { printf 'FAIL: PIC10F320 compiler omitted its monolithic source for %s\n' \
					"$variant" >&2; exit 1; }
			for unexpected in "$repo"/src/bypass_output_*.c; do
				! command_has_arg "$command" "$unexpected" \
					|| { printf 'FAIL: PIC10F320 compiler consumed modular driver %s\n' \
						"$unexpected" >&2; exit 1; }
			done
		else
			command_has_arg "$command" "$expected_driver" \
				|| { printf 'FAIL: %s compiler used the wrong driver for %s\n' \
					"$PB_LABEL" "$variant" >&2; exit 1; }
			for unexpected in CD4053_SIMPLE CD4053_WITH_MUTE TQ2_L2_5V_RELAY; do
				if [ "$unexpected" != "$expected_macro" ] \
						&& command_has_arg "$command" "-D$unexpected"; then
					printf 'FAIL: %s compiler mixed selectors for %s\n' \
						"$PB_LABEL" "$variant" >&2
					exit 1
				fi
			done
			for unexpected in \
					"$repo/src/bypass_output_cd4053_simple.c" \
					"$repo/src/bypass_output_cd4053_with_mute.c" \
					"$repo/src/bypass_output_tq2_l2_5v_relay.c" \
					"$repo/src/bypass_output_unlisted.c"; do
				if [ "$unexpected" != "$expected_driver" ] \
						&& command_has_arg "$command" "$unexpected"; then
					printf 'FAIL: %s compiler mixed or added driver %s for %s\n' \
						"$PB_LABEL" "$unexpected" "$variant" >&2
					exit 1
				fi
			done
		fi
	done
}

count_exact_lines() {
	local expected=$1 text=$2 line count=0
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$line" = "$expected" ]; then count=$((count + 1)); fi
	done <<< "$text"
	printf '%d\n' "$count"
}

assert_pic12f675_resource_records() {
	local output=$1 mode=$2 variant used data_record flash_record
	for variant in $PB_MATRIX_VARIANTS; do
		case "$mode:$variant" in
			boundary:*) used=48 ;;
			xc8-tie:*) used=36 ;;
			spaced:*) used=32 ;;
			*:cd4053_with_mute) used=33 ;;
			*:tq2_l2_5v_relay) used=34 ;;
			*) used=32 ;;
		esac
		data_record="PIC12F675_DATA_BUDGET PASS variant=$variant used=$used limit=48 capacity=64"
		[ "$(count_exact_lines "$data_record" "$output")" -eq 1 ] \
			|| { printf 'FAIL: PIC12F675 build did not emit exactly one normalized data record: %s\n' \
				"$data_record" >&2; exit 1; }
		flash_record="OK:   $variant -> $PB_BUILD_DIR/$PB_FW_BASE-$PB_TAG-$variant.hex : 42 words (4.1%) of 1024"
		[ "$(count_exact_lines "$flash_record" "$output")" -eq 1 ] \
			|| { printf 'FAIL: PIC12F675 flash OK grammar changed or was duplicated: %s\n' \
				"$flash_record" >&2; exit 1; }
	done
}

assert_host_output_counts() {
	local expected=$1 label=$2 output actual
	shift 2
	for output in "$@"; do
		actual=$(logged_command_count "$host_cc_log" "$output")
		[ "$actual" -eq "$expected" ] \
			|| { printf 'FAIL: %s compiled %s %d times, expected %d\n' \
				"$label" "$output" "$actual" "$expected" >&2; exit 1; }
	done
}

assert_host_run_count() {
	local expected=$1 label=$2 executable=$3 invoked count=0
	while IFS= read -r invoked; do
		if [ "$invoked" = "$executable" ]; then count=$((count + 1)); fi
	done < "$host_run_log"
	[ "$count" -eq "$expected" ] \
		|| { printf 'FAIL: %s executed %s %d times, expected %d\n' \
			"$label" "$executable" "$count" "$expected" >&2; exit 1; }
}

# Same fake toolchain, but aimed at whichever target owns the variant matrix.
run_matrix_make() {
	make --no-print-directory -C "$repo" "$PB_MATRIX_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" STRICT_TOOLS=1 AWK=awk "$@"
}

run_expected_hash_make() {
	make --no-print-directory -C "$repo" pic10f320-test-build \
		CC=true HOSTCC=true PIC10F320_CC="$tools/xc8" PIC10F320_BUILD_DIR="$PB_BUILD_DIR" \
		FW_BASE="$PB_FW_BASE" PIC10F320_TAG="$PB_TAG" \
		PIC10F320_FLASH_WORDS="$PB_FLASH_WORDS" \
		PIC10F320_VARIANTS_ALL="$PB_MATRIX_VARIANTS" STRICT_TOOLS=1 AWK=awk "$@"
}

run_stack_make() {
	make --no-print-directory -C "$repo" "$PB_STACK_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" \
		"$PB_VARIANT_VAR=$PB_VARIANT" \
		"$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS" \
		"$PB_STACK_DEVICE_VAR=8" PIC_STACK_DEPTH_GATE=./test/check_stack_depth_pic.sh \
		STRICT_TOOLS=1 AWK=awk "$@"
}

seed_stale_final_products() {
	printf 'stale image\n' > "$hex"
	printf 'stale assembly\n' > "$asm"
	printf 'stale symbols\n' > "$sym"
}

assert_no_final_products() {
	local label=$1 path
	for path in "$hex" "$asm" "$sym"; do
		[[ ! -e "$path" && ! -L "$path" ]] \
			|| { printf 'FAIL: %s left stale PIC product %s\n' "$label" "$path" >&2; exit 1; }
	done
}

remove_matrix_images() {
	local image ext path
	for image in $PB_MATRIX_IMAGES; do
		for ext in hex s sym; do
			path="$repo/$PB_BUILD_DIR/${image%.hex}.$ext"
			rm -f "$path"
		done
	done
}

seed_stale_matrix_products() {
	local image ext path
	mkdir -p "$repo/$PB_BUILD_DIR"
	for image in $PB_MATRIX_IMAGES; do
		for ext in hex s sym; do
			path="$repo/$PB_BUILD_DIR/${image%.hex}.$ext"
			printf 'stale product\n' > "$path"
		done
	done
}

assert_no_matrix_products() {
	local label=$1 image ext path
	for image in $PB_MATRIX_IMAGES; do
		for ext in hex s sym; do
			path="$repo/$PB_BUILD_DIR/${image%.hex}.$ext"
			[[ ! -e "$path" && ! -L "$path" ]] \
				|| { printf 'FAIL: %s left PIC product %s\n' \
					"$label" "$path" >&2; exit 1; }
		done
	done
}

assert_no_matrix_sidecars() {
	local label=$1 image ext path
	for image in $PB_MATRIX_IMAGES; do
		for ext in s sym; do
			path="$repo/$PB_BUILD_DIR/${image%.hex}.$ext"
			[[ ! -e "$path" && ! -L "$path" ]] \
				|| { printf 'FAIL: %s left PIC sidecar %s\n' \
					"$label" "$path" >&2; exit 1; }
		done
	done
}

expect_build_matrix_rejected() {
	local label=$1 matrix=$2 marker=$3 output
	shift 3
	remove_matrix_images
	if output=$(run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$matrix" "$@" 2>&1); then
		printf 'FAIL: %s build matrix accepted %s\n' "$PB_LABEL" "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$marker"* ]] \
		|| { printf 'FAIL: %s build matrix reported the wrong %s error: %s\n' \
			"$PB_LABEL" "$label" "$output" >&2; exit 1; }
	assert_no_matrix_products "rejected $PB_LABEL matrix"
	checks=$((checks + 1))
}

expect_data_mode_rejected() {
	local mode=$1 label=$2 output
	shift 2
	seed_stale_matrix_products
	if output=$(export FAKE_XC8_DATA_MODE="$mode"; run_matrix_make "$@" 2>&1); then
		printf 'FAIL: PIC12F675 data gate accepted %s\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"PIC12F675 data-budget gate:"* ]] \
		|| { printf 'FAIL: PIC12F675 %s failed outside the canonical data gate: %s\n' \
			"$label" "$output" >&2; exit 1; }
	assert_no_matrix_products "rejected PIC12F675 data transcript ($label)"
	checks=$((checks + 1))
}

expect_data_limit_rejected() {
	local label=$1 value=$2 output
	seed_stale_matrix_products
	if output=$(run_matrix_make "PIC12F675_DATA_LIMIT=$value" 2>&1); then
		printf 'FAIL: PIC12F675 data gate accepted %s policy limit\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"policy limit must be a positive decimal integer no greater than 64"* ]] \
		|| { printf 'FAIL: PIC12F675 %s policy limit failed for the wrong reason: %s\n' \
			"$label" "$output" >&2; exit 1; }
	assert_no_matrix_products "rejected PIC12F675 data limit ($label)"
	checks=$((checks + 1))
}

run_size_make() {
	make --no-print-directory -C "$repo" "$PB_SIZE_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" \
		"$PB_VARIANT_VAR=$PB_VARIANT" STRICT_TOOLS=1 AWK=awk "$@"
}

assert_no_size_probe() {
	local path
	for path in "$size_probe_stem".*; do
		[[ ! -e "$path" && ! -L "$path" ]] \
			|| { printf 'FAIL: size target left temporary artifact %s\n' "$path" >&2; exit 1; }
	done
}

expect_size_mode_rejected() {
	local mode=$1
	printf 'stale probe\n' > "$size_probe_stem.hex"
	if (export FAKE_XC8_MODE="$mode"; run_size_make) >/dev/null 2>&1; then
		printf 'FAIL: PIC size target accepted XC8 mode %s\n' "$mode" >&2
		exit 1
	fi
	assert_no_size_probe
	checks=$((checks + 1))
}

expect_override_rejected() {
	local label=$1
	shift
	printf 'stale image\n' > "$hex"
	if run_make "$@" >/dev/null 2>&1; then
		printf 'FAIL: PIC build accepted %s\n' "$label" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: %s left a stale PIC image\n' "$label" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_oracle_image_rejected() {
	local label=$1 mode=$2
	shift 2
	printf 'stale image\n' > "$hex"
	if (export FAKE_XC8_MODE="$mode"; run_make "$@") >/dev/null 2>&1; then
		printf 'FAIL: PIC10F320 build accepted %s\n' "$label" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: %s left a rejected PIC10F320 image\n' "$label" >&2; exit 1; }
	checks=$((checks + 1))
}

build_output=$(run_make)
"$repo/scripts/validate-ihex.sh" "$hex"
for sidecar in "$asm" "$sym"; do
	[[ -f "$sidecar" && ! -L "$sidecar" && -s "$sidecar" ]] \
		|| { printf 'FAIL: successful %s build did not retain fresh sidecar %s\n' \
			"$PB_LABEL" "$sidecar" >&2; exit 1; }
done
checks=$((checks + 1))

# Pin every shipping producer's variant-to-selector/source contract with
# test-owned literals. The exact three-command matrix also proves that merely
# adding an unlisted driver does not create a product.
: > "$xc8_log"
run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS" >/dev/null
assert_firmware_variant_contracts
checks=$((checks + 1))

if [ "$PB_PROFILE" = pic10f320 ]; then
	: > "$xc8_log"
	run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS" \
		PIC10F320_OUTPUT_MACRO=OUTPUT_TQ2_RELAY \
		PIC10F320_OUTPUT_DEF=-DOUTPUT_TQ2_RELAY \
		pic10f320_macro_cd4053_simple=OUTPUT_TQ2_RELAY >/dev/null
	assert_firmware_variant_contracts
	checks=$((checks + 1))
fi

if [ "$PB_TARGET" = pic12f675 ]; then
	assert_pic12f675_resource_records "$build_output" default
	checks=$((checks + 1))

	boundary_output=$(export FAKE_XC8_DATA_MODE=boundary; run_matrix_make)
	assert_pic12f675_resource_records "$boundary_output" boundary
	checks=$((checks + 1))

	spaced_output=$(export FAKE_XC8_DATA_MODE=spaced; run_matrix_make)
	assert_pic12f675_resource_records "$spaced_output" spaced
	checks=$((checks + 1))

	xc8_tie_output=$(export FAKE_XC8_DATA_MODE=xc8-tie; run_matrix_make)
	assert_pic12f675_resource_records "$xc8_tie_output" xc8-tie
	checks=$((checks + 1))

	immutable_output=$(run_matrix_make PIC12F675_DATA_BYTES=999)
	assert_pic12f675_resource_records "$immutable_output" default
	checks=$((checks + 1))

	for spec in \
		'missing:missing record' \
		'duplicate:duplicate records' \
		'malformed:malformed record' \
		'bad-percent:malformed percentage' \
		'percent-mismatch:inconsistent percentage' \
		'mixed-malformed:extra malformed record' \
		'trailing:trailing record text' \
		'wrong-unit:wrong data-space unit' \
		'zero:zero usage' \
		'over-limit:over-limit usage' \
		'huge:huge usage' \
		'used-mismatch:mismatched used counts' \
		'capacity-hex:wrong hexadecimal capacity'; do
		mode=${spec%%:*}; label=${spec#*:}
		expect_data_mode_rejected "$mode" "$label"
	done

	expect_data_limit_rejected empty ''
	expect_data_limit_rejected malformed malformed
	expect_data_limit_rejected negative -1
	expect_data_limit_rejected fractional 48.0
	expect_data_limit_rejected zero 0
	expect_data_limit_rejected over-capacity 65
	expect_data_limit_rejected huge 9999999999999999999999999999999999999999

	expect_data_mode_rejected malformed 'an attempted parser override' \
		"PIC12F675_DATA_BUDGET_GATE=$tools/noop-data-gate"

	canonical_gate="$repo/test/check_pic_data_budget.sh"
	moved_gate="$tools/check_pic_data_budget.sh"
	mv "$canonical_gate" "$moved_gate"
	ln -s "$moved_gate" "$canonical_gate"
	seed_stale_matrix_products
	if symlink_output=$(run_matrix_make 2>&1); then
		symlink_accepted=1
	else
		symlink_accepted=0
	fi
	rm -f "$canonical_gate"
	mv "$moved_gate" "$canonical_gate"
	[ "$symlink_accepted" -eq 0 ] \
		|| { printf 'FAIL: PIC12F675 build accepted a symlinked canonical data gate\n' >&2; exit 1; }
	[[ "$symlink_output" == *"canonical PIC12F675 data-budget gate is missing, symlinked, or not executable"* ]] \
		|| { printf 'FAIL: symlinked PIC12F675 data gate failed for the wrong reason: %s\n' \
			"$symlink_output" >&2; exit 1; }
	assert_no_matrix_products 'symlinked canonical PIC12F675 data gate'
	checks=$((checks + 1))

	mv "$canonical_gate" "$moved_gate"
	seed_stale_matrix_products
	if missing_output=$(run_matrix_make 2>&1); then
		missing_accepted=1
	else
		missing_accepted=0
	fi
	mv "$moved_gate" "$canonical_gate"
	[ "$missing_accepted" -eq 0 ] \
		|| { printf 'FAIL: PIC12F675 build accepted a missing canonical data gate\n' >&2; exit 1; }
	[[ "$missing_output" == *"canonical PIC12F675 data-budget gate is missing, symlinked, or not executable"* ]] \
		|| { printf 'FAIL: missing PIC12F675 data gate failed for the wrong reason: %s\n' \
			"$missing_output" >&2; exit 1; }
	assert_no_matrix_products 'missing canonical PIC12F675 data gate'
	checks=$((checks + 1))

	chmod 640 "$canonical_gate"
	seed_stale_matrix_products
	if nonexec_output=$(run_matrix_make 2>&1); then
		nonexec_accepted=1
	else
		nonexec_accepted=0
	fi
	chmod 750 "$canonical_gate"
	[ "$nonexec_accepted" -eq 0 ] \
		|| { printf 'FAIL: PIC12F675 build accepted a non-executable canonical data gate\n' >&2; exit 1; }
	[[ "$nonexec_output" == *"canonical PIC12F675 data-budget gate is missing, symlinked, or not executable"* ]] \
		|| { printf 'FAIL: non-executable PIC12F675 data gate failed for the wrong reason: %s\n' \
			"$nonexec_output" >&2; exit 1; }
	assert_no_matrix_products 'non-executable canonical PIC12F675 data gate'
	checks=$((checks + 1))

	seed_stale_matrix_products
	if (export FAKE_XC8_DATA_FAIL_NAME="$PB_MATRIX_FAIL_IMAGE"; \
			run_matrix_make) >/dev/null 2>&1; then
		printf 'FAIL: late PIC12F675 data-budget failure was accepted\n' >&2
		exit 1
	fi
	assert_no_matrix_products 'late PIC12F675 matrix data-budget failure'
	checks=$((checks + 1))
fi

# PIC12F675 simulator images carry a fabricated oscillator-calibration word and
# must never sit beside shipping images. The producer derives its directory from
# the caller-selected build root and deliberately overrides a direct collision
# attempt. Query the real copied Makefile so this test pins the Make expansion,
# rather than restating the intended assignment in shell.
if [ "$PB_TARGET" = pic12f675 ]; then
	simcal_dir=$(make -s --no-print-directory -C "$repo" \
		CC=true HOSTCC=true \
		"$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		PIC12F675_SIMCAL_DIR="$PB_BUILD_DIR" \
		print-PIC12F675_SIMCAL_DIR 2>/dev/null)
	[ "$simcal_dir" = "$PB_BUILD_DIR/simcal" ] \
		|| { printf 'FAIL: PIC12F675_SIMCAL_DIR collision override resolved to %s, expected %s/simcal\n' \
			"$simcal_dir" "$PB_BUILD_DIR" >&2; exit 1; }
	checks=$((checks + 1))
fi

# Missing XC8 is a valid development-time skip, but only after every stale
# product has been removed. Exercise the public stack target so a stale HEX
# cannot convert that skip into a later false gate attempt.
run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS" >/dev/null
if ! output=$(run_stack_make "$PB_CC_VAR=$tools/missing-xc8" STRICT_TOOLS= \
		"${product_override_args[@]}" 2>&1); then
	printf 'FAIL: %s stack target did not skip a missing XC8: %s\n' \
		"$PB_LABEL" "$output" >&2
	exit 1
fi
[[ "$output" == *"skipping stack-depth gate"* ]] \
	|| { printf 'FAIL: %s missing-XC8 stack target reported the wrong result: %s\n' \
		"$PB_LABEL" "$output" >&2; exit 1; }
assert_no_matrix_products "$PB_LABEL missing-XC8 skip"
checks=$((checks + 1))

# A successful compiler can produce a current HEX without the optional outputs
# consumed by later gates. The build must first remove the prior valid sidecars,
# and the stack target must fail rather than treating their absence as no XC8.
run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS" >/dev/null
if output=$(export FAKE_XC8_MODE=no-sidecars; run_stack_make 2>&1); then
	printf 'FAIL: %s stack gate accepted current HEX images without fresh assembly\n' \
		"$PB_LABEL" >&2
	exit 1
fi
[[ "$output" == *"generated assembly is missing, empty, or not regular"* ]] \
	|| { printf 'FAIL: %s missing-assembly gate failed for the wrong reason: %s\n' \
		"$PB_LABEL" "$output" >&2; exit 1; }
[[ -s "$hex" ]] \
	|| { printf 'FAIL: %s missing-assembly fixture did not retain its current HEX\n' \
		"$PB_LABEL" >&2; exit 1; }
assert_no_matrix_sidecars "$PB_LABEL current-HEX-only build"
checks=$((checks + 1))

if [ "$PB_RETURN_STACK_REQUIRED" -eq 1 ]; then
	expect_oracle_image_rejected "a reachable RETFIE image" bad-stack
	expect_oracle_image_rejected \
		"a reachable RETFIE image with a successful no-op oracle override" bad-stack \
		"PIC10F320_RETURN_STACK_ORACLE=$tools/noop-oracle.py"

	bad_depth_fixture="$work/depth-9.hex"
	FAKE_XC8_MODE=bad-depth "$tools/xc8" -o "$bad_depth_fixture" >/dev/null
	"$repo/scripts/validate-ihex.sh" "$bad_depth_fixture"
	python3 "$repo/test/pic10f320/return_stack_oracle.py" \
		--limit 9 "$bad_depth_fixture" >/dev/null \
		|| { printf 'FAIL: precomputed depth-9 fixture is not valid at limit 9\n' >&2; exit 1; }
	if python3 "$repo/test/pic10f320/return_stack_oracle.py" \
			--limit 8 "$bad_depth_fixture" >/dev/null 2>&1; then
		printf 'FAIL: precomputed depth-9 fixture passed the architectural limit\n' >&2
		exit 1
	fi
	checks=$((checks + 1))

	expect_oracle_image_rejected \
		"a depth-9 image with PIC10F320_RETURN_STACK_LIMIT=99" bad-depth \
		PIC10F320_RETURN_STACK_LIMIT=99
fi

for mode in over-budget huge-count; do
	printf 'stale image\n' > "$hex"
	if (export FAKE_XC8_MODE="$mode"; run_make) >/dev/null 2>&1; then
		printf 'FAIL: PIC build accepted budget mode %s\n' "$mode" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: budget mode %s left a stale image\n' "$mode" >&2; exit 1; }
	checks=$((checks + 1))
done

for mode in no-summary program-malformed program-duplicate program-mixed \
		program-zero program-percent; do
	printf 'stale image\n' > "$hex"
	if (export FAKE_XC8_MODE="$mode"; run_make) >/dev/null 2>&1; then
		printf 'FAIL: PIC build accepted program-summary mode %s\n' "$mode" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: program-summary mode %s left a stale image\n' "$mode" >&2; exit 1; }
	checks=$((checks + 1))
done

canonical_program_parser="$repo/test/parse_xc8_program_space.sh"
moved_program_parser="$tools/parse_xc8_program_space.sh"
mv "$canonical_program_parser" "$moved_program_parser"
ln -s "$moved_program_parser" "$canonical_program_parser"
seed_stale_final_products
if symlink_output=$(run_make 2>&1); then
	symlink_accepted=1
else
	symlink_accepted=0
fi
rm -f "$canonical_program_parser"
mv "$moved_program_parser" "$canonical_program_parser"
[[ $symlink_accepted -eq 0 \
	&& $symlink_output == *"XC8 program-space parser is missing, symlinked, or not executable"* ]] \
	|| { printf 'FAIL: symlinked XC8 program parser produced the wrong result: %s\n' \
		"$symlink_output" >&2; exit 1; }
assert_no_final_products "symlinked XC8 program parser"
checks=$((checks + 1))

mv "$canonical_program_parser" "$moved_program_parser"
seed_stale_final_products
if missing_output=$(run_make 2>&1); then
	missing_accepted=1
else
	missing_accepted=0
fi
mv "$moved_program_parser" "$canonical_program_parser"
[[ $missing_accepted -eq 0 \
	&& $missing_output == *"XC8 program-space parser is missing, symlinked, or not executable"* ]] \
	|| { printf 'FAIL: missing XC8 program parser produced the wrong result: %s\n' \
		"$missing_output" >&2; exit 1; }
assert_no_final_products "missing XC8 program parser"
checks=$((checks + 1))

chmod 640 "$canonical_program_parser"
seed_stale_final_products
if nonexec_output=$(run_make 2>&1); then
	nonexec_accepted=1
else
	nonexec_accepted=0
fi
chmod 750 "$canonical_program_parser"
[[ $nonexec_accepted -eq 0 \
	&& $nonexec_output == *"XC8 program-space parser is missing, symlinked, or not executable"* ]] \
	|| { printf 'FAIL: non-executable XC8 program parser produced the wrong result: %s\n' \
		"$nonexec_output" >&2; exit 1; }
assert_no_final_products "non-executable XC8 program parser"
checks=$((checks + 1))

seed_stale_final_products
if (export FAKE_XC8_MODE=program-malformed; \
		run_make "XC8_PROGRAM_SPACE_PARSER=$tools/noop-data-gate") >/dev/null 2>&1; then
	printf 'FAIL: PIC build accepted a program-parser override\n' >&2
	exit 1
fi
assert_no_final_products "attempted XC8 program parser override"
checks=$((checks + 1))

expect_override_rejected "an empty flash budget" "$PB_FLASH_VAR="
expect_override_rejected "a malformed flash budget" $PB_FLASH_VAR=malformed
expect_override_rejected "a negative flash budget" $PB_FLASH_VAR=-1
expect_override_rejected "a non-integer flash budget" $PB_FLASH_VAR=512.0
expect_override_rejected "a zero flash budget" $PB_FLASH_VAR=0
expect_override_rejected "a failed budget comparison" \
	$PB_FLASH_VAR=41 AWK="$tools/failing-awk"
expect_override_rejected "a status-1 budget comparison failure" \
	$PB_FLASH_VAR=41 AWK="$tools/status1-comparison-awk"
expect_override_rejected "an invalid budget comparison result" \
	$PB_FLASH_VAR=41 AWK="$tools/invalid-comparison-awk"
expect_override_rejected "a failed percentage calculation" \
	AWK="$tools/failing-awk"
expect_override_rejected "an empty percentage result" \
	AWK="$tools/empty-awk"
expect_override_rejected "an invalid percentage result" \
	AWK="$tools/invalid-percentage-awk"

# Leading-zero budget parsing, proved in both directions. The pinned budget is
# this lane's own with zeros prepended, so it stays consistent with the
# over-budget fixture above (which is one word past the same number) rather than
# pinning a second part's 512 that a 1024-word lane is legitimately under.
leading_zero_budget=000$PB_FLASH_WORDS
(export FAKE_XC8_MODE=leading-count; run_make $PB_FLASH_VAR=$leading_zero_budget) >/dev/null
"$repo/scripts/validate-ihex.sh" "$hex"
checks=$((checks + 1))

printf 'stale image\n' > "$hex"
if (export FAKE_XC8_MODE=over-budget; \
		run_make $PB_FLASH_VAR=$leading_zero_budget) >/dev/null 2>&1; then
	printf 'FAIL: leading-zero flash budget bypassed the limit\n' >&2
	exit 1
fi
[[ ! -e "$hex" && ! -L "$hex" ]] \
	|| { printf 'FAIL: leading-zero flash budget left a stale image\n' >&2; exit 1; }
checks=$((checks + 1))

printf 'stale image\n' > "$hex"
if (export FAKE_XC8_MODE=leading-count; \
		run_make $PB_FLASH_VAR=41) >/dev/null 2>&1; then
	printf 'FAIL: leading-zero usage count bypassed the limit\n' >&2
	exit 1
fi
[[ ! -e "$hex" && ! -L "$hex" ]] \
	|| { printf 'FAIL: leading-zero usage count left a stale image\n' >&2; exit 1; }
checks=$((checks + 1))

for mode in fail missing empty bad-checksum eof-only trailing symlink; do
	seed_stale_final_products
	if (export FAKE_XC8_MODE="$mode"; run_make) >/dev/null 2>&1; then
		printf 'FAIL: XC8 mode %s was accepted\n' "$mode" >&2
		exit 1
	fi
	assert_no_final_products "XC8 mode $mode"
	checks=$((checks + 1))
done

marker="$work/build.signal-delivered"
rm -f "$marker"
seed_stale_final_products
if (export FAKE_XC8_MODE=signal FAKE_XC8_SIGNAL_MARKER="$marker"; \
		run_make) >/dev/null 2>&1; then
	printf 'FAIL: interrupted PIC build exited successfully\n' >&2
	exit 1
fi
[[ -f "$marker" ]] \
	|| { printf 'FAIL: PIC build signal fixture did not deliver SIGTERM\n' >&2; exit 1; }
assert_no_final_products "interrupted PIC build"
checks=$((checks + 1))

printf 'stale image\n' > "$hex"
if run_make IHEX_VALIDATOR="$repo/scripts/missing-validator" >/dev/null 2>&1; then
	printf 'FAIL: missing Intel HEX validator was accepted\n' >&2
	exit 1
fi
[[ ! -e "$hex" ]] \
	|| { printf 'FAIL: missing validator left a stale PIC image\n' >&2; exit 1; }
checks=$((checks + 1))

if run_matrix_make "$PB_MATRIX_VARIANTS_VAR=" >/dev/null 2>&1; then
	printf 'FAIL: empty %s variant matrix was accepted\n' "$PB_LABEL" >&2
	exit 1
fi
checks=$((checks + 1))

if [ "$PB_MATRIX_REQUIRE_COMPLETE" -eq 1 ]; then
	remove_matrix_images
	run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS" >/dev/null
	for image in $PB_MATRIX_IMAGES; do
		"$repo/scripts/validate-ihex.sh" "$repo/$PB_BUILD_DIR/$image"
	done
	checks=$((checks + 1))

	if [ "$PB_TARGET" = pic10f320 ]; then
		run_expected_hash_make >/dev/null
		checks=$((checks + 1))

		if output=$(export FAKE_XC8_MODE=hash-mismatch; run_expected_hash_make 2>&1); then
			printf 'FAIL: PIC10F320 expected-image gate accepted changed image bytes\n' >&2
			exit 1
		fi
		[[ "$output" == *"SHA-256 mismatch"* ]] \
			|| { printf 'FAIL: changed PIC10F320 image failed for the wrong reason: %s\n' \
				"$output" >&2; exit 1; }
		for image in $PB_MATRIX_IMAGES; do
			[[ -s "$repo/$PB_BUILD_DIR/$image" ]] \
				|| { printf 'FAIL: hash mismatch removed inspectable image %s\n' \
					"$image" >&2; exit 1; }
		done
		checks=$((checks + 1))

		baseline="$repo/test/pic10f320/expected_images.sha256"
		cp "$baseline" "$work/expected_images.sha256"
		printf 'malformed baseline\n' > "$baseline"
		if output=$(run_expected_hash_make 2>&1); then
			printf 'FAIL: PIC10F320 expected-image gate accepted a malformed baseline\n' >&2
			exit 1
		fi
		[[ "$output" == *"manifest"* ]] \
			|| { printf 'FAIL: malformed PIC10F320 baseline failed for the wrong reason: %s\n' \
				"$output" >&2; exit 1; }
		cp "$work/expected_images.sha256" "$baseline"
		checks=$((checks + 1))

		checker="$repo/test/pic10f320/check_expected_images.py"
		mv "$checker" "$work/check_expected_images.py"
		if output=$(run_expected_hash_make 2>&1); then
			printf 'FAIL: PIC10F320 expected-image gate accepted a missing checker\n' >&2
			exit 1
		fi
		[[ "$output" == *"checker is missing or invalid"* ]] \
			|| { printf 'FAIL: missing PIC10F320 checker failed for the wrong reason: %s\n' \
				"$output" >&2; exit 1; }
		mv "$work/check_expected_images.py" "$checker"
		checks=$((checks + 1))
	fi

	expect_build_matrix_rejected "an incomplete set" "$PB_VARIANT" \
		"$PB_MATRIX_VARIANTS_VAR must contain every supported name"
	expect_build_matrix_rejected "duplicate names" \
		"$PB_MATRIX_VARIANTS $PB_VARIANT" \
		"$PB_MATRIX_VARIANTS_VAR must not contain duplicate names"
	expect_build_matrix_rejected "an unsupported name" "$PB_MATRIX_UNSUPPORTED" \
		"$PB_MATRIX_VARIANTS_VAR contains unsupported names"
	injection_marker="$work/$PB_TARGET-matrix-injected"
	rm -f "$injection_marker"
	injected_matrix="$PB_MATRIX_UNSUPPORTED; touch $injection_marker; exit 0"
	expect_build_matrix_rejected "shell syntax in a variant name" \
		"$injected_matrix" \
		"$PB_MATRIX_VARIANTS_VAR contains unsupported names"
	[[ ! -e "$injection_marker" ]] \
		|| { printf 'FAIL: %s matrix text executed shell syntax\n' "$PB_LABEL" >&2; exit 1; }
	# A variant name that rewrites the supported set it is about to be checked
	# against. Applies to every target whose supported set is a Make variable the
	# request can reach -- keyed on that variable, not on a part name, so a new
	# part built on the same machinery cannot quietly skip it.
	if [ -n "$matrix_supported_var" ]; then
		eval_marker="$work/$PB_TARGET-matrix-make-function-executed"
		rm -f "$eval_marker"
		malicious_matrix='$(eval override '"$matrix_supported_var"':=unknown)$(shell touch '"$eval_marker"')unknown'
		expect_build_matrix_rejected \
			"a recursively self-whitelisting unsupported name" \
			"$malicious_matrix" \
			"$PB_MATRIX_VARIANTS_VAR contains unsupported names"
		[[ ! -e "$eval_marker" ]] \
			|| { printf 'FAIL: %s matrix text executed a GNU Make function\n' "$PB_LABEL" >&2; exit 1; }
	fi
fi

if (export FAKE_XC8_FAIL_NAME="$PB_MATRIX_FAIL_IMAGE"; \
		run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS") >/dev/null 2>&1; then
	printf 'FAIL: late %s variant compiler failure was accepted\n' "$PB_LABEL" >&2
	exit 1
fi
assert_no_matrix_products "late $PB_LABEL matrix compiler failure"
checks=$((checks + 1))

seed_stale_matrix_products
if (export FAKE_XC8_PROGRAM_FAIL_NAME="$PB_MATRIX_FAIL_IMAGE"; \
		run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS") >/dev/null 2>&1; then
	printf 'FAIL: late %s variant program-summary failure was accepted\n' "$PB_LABEL" >&2
	exit 1
fi
assert_no_matrix_products "late $PB_LABEL matrix program-summary failure"
checks=$((checks + 1))

# PIC10F320's target/soak lanes have selectors separate from PIC10F320_VARIANT.
# Each selector must control the image rebuilt by the pic10f320 prerequisite, even
# when a caller supplies a conflicting PIC10F320_VARIANT that names a stale image.
if [ "$PB_SELECTOR_ROUTING" -eq 1 ]; then
	selected=tq2_l2_5v_relay
	selected_hex=$(pb_image "$selected")
	selector_specs=(
		"pic10f320-test-fault-target PIC10F320_FAULT_VARIANT"
		"pic10f320-test-lockstep PIC10F320_LOCKSTEP_VARIANT"
		"pic10f320-test-io PIC10F320_IO_VARIANT"
		"pic10f320-test-soak PIC10F320_SOAK_VARIANT"
	)
	for spec in "${selector_specs[@]}"; do
		read -r target selector <<<"$spec"
		rm -f "$hex" "$selected_hex"
		if ! make --no-print-directory -C "$repo" "$target" \
				CC=true HOSTCC=true PIC10F320_CC="$tools/xc8" \
				PIC10F320_BUILD_DIR="$PB_BUILD_DIR" FW_BASE="$PB_FW_BASE" \
				PIC10F320_TAG="$PB_TAG" PIC10F320_FLASH_WORDS="$PB_FLASH_WORDS" \
				PIC10F320_VARIANT="$PB_VARIANT" "$selector=$selected" \
				PIC10F320_SOAK_CXX="$tools/missing-cxx" STRICT_TOOLS= AWK=awk \
				>/dev/null 2>&1; then
			printf 'FAIL: %s did not skip cleanly after building its selected variant\n' \
				"$target" >&2
			exit 1
		fi
		[[ -s "$selected_hex" && ! -e "$hex" ]] \
			|| { printf 'FAIL: %s built %s instead of selected %s\n' \
				"$target" "$hex" "$selected_hex" >&2; exit 1; }
		checks=$((checks + 1))
	done

	# The shipping compiler and all three target-test binary producers must read
	# the same PIC10F320 selector map. Execute each final C++ command for every
	# variant; do not infer expected selectors from Make.
	: > "$target_cc_log"
	target_compile_specs=(
		"pic10f320-test-fault-target PIC10F320_FAULT_VARIANT test_fault_pic"
		"pic10f320-test-io PIC10F320_IO_VARIANT test_io_pic"
		"pic10f320-test-lockstep PIC10F320_LOCKSTEP_VARIANT test_lockstep_pic"
	)
	for variant in "${PB_CANONICAL_VARIANTS[@]}"; do
		case "$variant" in
			cd4053_simple) expected_macro=OUTPUT_CD4053_SIMPLE ;;
			cd4053_with_mute) expected_macro=OUTPUT_CD4053_WITH_MUTE ;;
			tq2_l2_5v_relay) expected_macro=OUTPUT_TQ2_RELAY ;;
		esac
		for spec in "${target_compile_specs[@]}"; do
			read -r target selector binary <<<"$spec"
			binary="$PB_BUILD_DIR/$binary"
			before=$(logged_command_count "$target_cc_log" "$binary")
			run_pic10f320_target_make "$target" "$selector" "$variant" >/dev/null
			[ "$(logged_command_count "$target_cc_log" "$binary")" -eq $((before + 1)) ] \
				|| { printf 'FAIL: %s did not compile its target binary exactly once for %s\n' \
					"$target" "$variant" >&2; exit 1; }
			command=$(latest_logged_command "$target_cc_log" "$binary")
			command_has_arg "$command" "-D$expected_macro" \
				|| { printf 'FAIL: %s used the wrong PIC10F320 selector for %s\n' \
					"$target" "$variant" >&2; exit 1; }
			for unexpected in OUTPUT_CD4053_SIMPLE OUTPUT_CD4053_WITH_MUTE OUTPUT_TQ2_RELAY; do
				if [ "$unexpected" != "$expected_macro" ] \
						&& command_has_arg "$command" "-D$unexpected"; then
					printf 'FAIL: %s mixed PIC10F320 selectors for %s\n' \
						"$target" "$variant" >&2
					exit 1
				fi
			done
			checks=$((checks + 1))
		done
	done
fi

if [ -n "$PB_SIZE_TARGET" ]; then
	size_output=$(run_size_make)
	[[ "$size_output" == *"Program space"* ]] \
		|| { printf 'FAIL: PIC size target did not print its memory summary\n' >&2; exit 1; }
	assert_no_size_probe
	checks=$((checks + 1))

	for mode in fail missing empty bad-checksum eof-only trailing symlink directory no-summary \
			program-malformed program-duplicate program-mixed program-zero program-percent; do
		expect_size_mode_rejected "$mode"
	done

	marker="$work/size.signal-delivered"
	rm -f "$marker"
	printf 'stale probe\n' > "$size_probe_stem.hex"
	if (export FAKE_XC8_MODE=signal FAKE_XC8_SIGNAL_MARKER="$marker"; \
			run_size_make) >/dev/null 2>&1; then
		printf 'FAIL: interrupted PIC size target exited successfully\n' >&2
		exit 1
	fi
	[[ -f "$marker" ]] \
		|| { printf 'FAIL: size signal fixture did not deliver SIGTERM\n' >&2; exit 1; }
	assert_no_size_probe
	checks=$((checks + 1))

	printf 'stale probe\n' > "$size_probe_stem.hex"
	if run_size_make IHEX_VALIDATOR="$repo/scripts/missing-validator" >/dev/null 2>&1; then
		printf 'FAIL: PIC size target accepted a missing Intel HEX validator\n' >&2
		exit 1
	fi
	assert_no_size_probe
	checks=$((checks + 1))

	printf 'stale probe\n' > "$size_probe_stem.hex"
	if ! size_output=$(run_size_make STRICT_TOOLS= \
			"$PB_CC_VAR=$tools/missing-xc8" 2>&1); then
		printf 'FAIL: PIC size target did not skip missing XC8 by default: %s\n' \
			"$size_output" >&2
		exit 1
	fi
	[[ "$size_output" == *"XC8 not found"* && "$size_output" != *"STRICT_TOOLS=1:"* ]] \
		|| { printf 'FAIL: PIC size target reported the wrong missing-XC8 skip\n' >&2; exit 1; }
	assert_no_size_probe
	checks=$((checks + 1))

	printf 'stale probe\n' > "$size_probe_stem.hex"
	if run_size_make "$PB_CC_VAR=$tools/missing-xc8" >/dev/null 2>&1; then
		printf 'FAIL: PIC size target accepted missing XC8 under STRICT_TOOLS=1\n' >&2
		exit 1
	fi
	assert_no_size_probe
	checks=$((checks + 1))
fi

if [ "$PB_REBUILD_REQUIRED" = 1 ]; then
	# This section deliberately reuses this script's fresh mktemp repository. Exact
	# output-specific compiler and execution counts prove that no pre-existing
	# artifact can satisfy a request. Same-name target sentinels make every repeat
	# depend on the Makefile's .PHONY declarations rather than filesystem absence.
	image_output=${hex##*/}
	image_count=$(logged_command_count "$xc8_log" "$image_output")
	run_make >/dev/null
	[[ "$(logged_command_count "$xc8_log" "$image_output")" -eq $((image_count + 1)) ]] \
		|| { printf 'FAIL: initial PIC10F320 rebuild probe did not invoke XC8 exactly once\n' >&2; exit 1; }
	latest=$(latest_logged_command "$xc8_log" "$image_output")
	command_has_arg "$latest" '-D_XTAL_FREQ=2000000UL' \
		&& command_has_arg "$latest" '-DOUTPUT_CD4053_SIMPLE' \
		|| { printf 'FAIL: initial PIC10F320 rebuild used stale clock/output flags\n' >&2; exit 1; }
	checks=$((checks + 1))
	: > "$repo/pic10f320"

	run_make >/dev/null
	[[ "$(logged_command_count "$xc8_log" "$image_output")" -eq $((image_count + 2)) ]] \
		|| { printf 'FAIL: identical PIC10F320 request reused a stale image\n' >&2; exit 1; }
	latest=$(latest_logged_command "$xc8_log" "$image_output")
	command_has_arg "$latest" '-D_XTAL_FREQ=2000000UL' \
		&& command_has_arg "$latest" '-DOUTPUT_CD4053_SIMPLE' \
		|| { printf 'FAIL: repeated PIC10F320 request used stale flags\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_make PIC10F320_XTAL=4000000UL >/dev/null
	[[ "$(logged_command_count "$xc8_log" "$image_output")" -eq $((image_count + 3)) ]] \
		|| { printf 'FAIL: changed PIC10F320_XTAL did not invoke XC8 exactly once\n' >&2; exit 1; }
	latest=$(latest_logged_command "$xc8_log" "$image_output")
	command_has_arg "$latest" '-D_XTAL_FREQ=4000000UL' \
		&& ! command_has_arg "$latest" '-D_XTAL_FREQ=2000000UL' \
		|| { printf 'FAIL: changed PIC10F320_XTAL did not reach the current XC8 invocation\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_make >/dev/null
	[[ "$(logged_command_count "$xc8_log" "$image_output")" -eq $((image_count + 4)) ]] \
		|| { printf 'FAIL: restored PIC10F320_XTAL did not invoke XC8 exactly once\n' >&2; exit 1; }
	latest=$(latest_logged_command "$xc8_log" "$image_output")
	command_has_arg "$latest" '-D_XTAL_FREQ=2000000UL' \
		&& ! command_has_arg "$latest" '-D_XTAL_FREQ=4000000UL' \
		|| { printf 'FAIL: restored PIC10F320_XTAL did not reach the current XC8 invocation\n' >&2; exit 1; }
	checks=$((checks + 1))

	equiv_outputs=(
		"$PB_BUILD_DIR/fw_harness.o"
		"$PB_BUILD_DIR/test_equiv_drv.o"
		"$PB_BUILD_DIR/bypass_pure_equiv.o"
		"$PB_BUILD_DIR/test_equiv"
	)
	run_pic10f320_host_make pic10f320-test-equiv >/dev/null
	assert_host_output_counts 1 'initial pic10f320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 1 'initial pic10f320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	checks=$((checks + 1))
	: > "$repo/pic10f320-test-equiv"
	run_pic10f320_host_make pic10f320-test-equiv >/dev/null
	assert_host_output_counts 2 'identical pic10f320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 2 'identical pic10f320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	checks=$((checks + 1))

	run_pic10f320_host_make pic10f320-test-equiv PIC10F320_VARIANT=cd4053_with_mute >/dev/null
	assert_host_output_counts 3 'changed-variant pic10f320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 3 'changed-variant pic10f320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	latest=$(latest_logged_command "$host_cc_log" "$PB_BUILD_DIR/fw_harness.o")
	command_has_arg "$latest" '-DOUTPUT_CD4053_WITH_MUTE' \
		&& ! command_has_arg "$latest" '-DOUTPUT_CD4053_SIMPLE' \
		|| { printf 'FAIL: changed PIC10F320_VARIANT did not reach the current shared harness compile\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_pic10f320_host_make pic10f320-test-equiv >/dev/null
	assert_host_output_counts 4 'restored-variant pic10f320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 4 'restored-variant pic10f320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	latest=$(latest_logged_command "$host_cc_log" "$PB_BUILD_DIR/fw_harness.o")
	command_has_arg "$latest" '-DOUTPUT_CD4053_SIMPLE' \
		&& ! command_has_arg "$latest" '-DOUTPUT_CD4053_WITH_MUTE' \
		|| { printf 'FAIL: restored PIC10F320_VARIANT did not reach the current shared harness compile\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_pic10f320_host_make pic10f320-test-equiv \
		PIC10F320_HOST_CFLAGS='-std=c11 -O0 -DPB_HOST_FLAGS_CHANGED' >/dev/null
	assert_host_output_counts 5 'changed-flags pic10f320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 5 'changed-flags pic10f320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	for output in "$PB_BUILD_DIR/test_equiv_drv.o" "$PB_BUILD_DIR/bypass_pure_equiv.o"; do
		latest=$(latest_logged_command "$host_cc_log" "$output")
		command_has_arg "$latest" '-DPB_HOST_FLAGS_CHANGED' \
			&& command_has_arg "$latest" '-O0' \
			|| { printf 'FAIL: changed PIC10F320_HOST_CFLAGS did not reach current compile for %s\n' \
				"$output" >&2; exit 1; }
	done
	checks=$((checks + 1))

	run_pic10f320_host_make pic10f320-test-equiv >/dev/null
	assert_host_output_counts 6 'restored-flags pic10f320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 6 'restored-flags pic10f320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	for output in "$PB_BUILD_DIR/test_equiv_drv.o" "$PB_BUILD_DIR/bypass_pure_equiv.o"; do
		latest=$(latest_logged_command "$host_cc_log" "$output")
		command_has_arg "$latest" '-O2' \
			&& command_has_arg "$latest" '-Wall' \
			&& command_has_arg "$latest" '-Wextra' \
			&& command_has_arg "$latest" '-Werror' \
			&& ! command_has_arg "$latest" '-DPB_HOST_FLAGS_CHANGED' \
			|| { printf 'FAIL: restored PIC10F320_HOST_CFLAGS did not reach current compile for %s\n' \
				"$output" >&2; exit 1; }
	done
	checks=$((checks + 1))

	actuation_outputs=(
		"$PB_BUILD_DIR/fw_harness_$PB_VARIANT.o"
		"$PB_BUILD_DIR/test_actuation_drv_$PB_VARIANT.o"
		"$PB_BUILD_DIR/test_actuation_$PB_VARIANT"
	)
	run_pic10f320_host_make pic10f320-test-actuation >/dev/null
	assert_host_output_counts 1 'initial pic10f320-test-actuation request' "${actuation_outputs[@]}"
	assert_host_run_count 1 'initial pic10f320-test-actuation request' \
		"$PB_BUILD_DIR/test_actuation_$PB_VARIANT"
	checks=$((checks + 1))
	: > "$repo/pic10f320-test-actuation"
	run_pic10f320_host_make pic10f320-test-actuation >/dev/null
	assert_host_output_counts 2 'identical pic10f320-test-actuation request' "${actuation_outputs[@]}"
	assert_host_run_count 2 'identical pic10f320-test-actuation request' \
		"$PB_BUILD_DIR/test_actuation_$PB_VARIANT"
	checks=$((checks + 1))

	fault_outputs=(
		"$PB_BUILD_DIR/fw_fault_harness.o"
		"$PB_BUILD_DIR/test_fault_drv.o"
		"$PB_BUILD_DIR/test_fault"
	)
	run_pic10f320_host_make pic10f320-test-fault-host >/dev/null
	assert_host_output_counts 1 'initial pic10f320-test-fault-host request' "${fault_outputs[@]}"
	assert_host_run_count 1 'initial pic10f320-test-fault-host request' "$PB_BUILD_DIR/test_fault"
	checks=$((checks + 1))
	: > "$repo/pic10f320-test-fault-host"
	run_pic10f320_host_make pic10f320-test-fault-host >/dev/null
	assert_host_output_counts 2 'identical pic10f320-test-fault-host request' "${fault_outputs[@]}"
	assert_host_run_count 2 'identical pic10f320-test-fault-host request' "$PB_BUILD_DIR/test_fault"
	checks=$((checks + 1))
fi

if [ "$PB_TARGET" = pic12f675 ]; then
	# Exercise the real calibration injector and Make recipes over a private,
	# minimal PIC12F675 HEX matrix. --old-file suppresses the fake-XC8 producer:
	# these checks isolate derived-set publication and consumption rather than
	# rebuilding the shipping images whose contract was established above.
	mkdir -p "$repo/test/pic" "$repo/$PB_BUILD_DIR"
	cp "$ROOT/test/.gitignore" "$repo/test/.gitignore"
	cp "$ROOT/test/pic/test_config_pic12f675.c" \
		"$repo/test/pic/test_config_pic12f675.c"
	cp "$ROOT/test/pic/test_config_pic_core.h" \
		"$repo/test/pic/test_config_pic_core.h"
	cp "$ROOT/test/pic/pic12f675_config.h" \
		"$repo/test/pic/pic12f675_config.h"
	cp "$ROOT/test/pic/inject_calibration_word.py" \
		"$repo/test/pic/inject_calibration_word.py"
	cp "$ROOT/test/pic/pic12f675_matrix_evidence.py" \
		"$repo/test/pic/pic12f675_matrix_evidence.py"
	cal_shipping=()
	cal_sim=()
	for image in $PB_MATRIX_IMAGES; do
		cal_shipping+=("$repo/$PB_BUILD_DIR/$image")
		cal_sim+=("$repo/$PB_BUILD_DIR/simcal/${image%.hex}_simcal.hex")
	done
	cal_extra="$repo/$PB_BUILD_DIR/simcal/unexpected_simcal.hex"
	cal_repo_lock_id=$(stat -Lc '%d:%i' "$repo")

	write_calibration_fixture() {
		printf '%s\n' \
			':040000000028FF23B2' \
			':02400E00CC31B3' \
			':00000001FF' > "$1"
	}

	run_simcal_make() {
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
			make --no-print-directory -C "$repo" --old-file=pic12f675 pic12f675-simcal \
			CC=true HOSTCC=true PIC12F675_BUILD_DIR="$PB_BUILD_DIR" \
			FW_BASE="$PB_FW_BASE" PIC12F675_TAG="$PB_TAG" \
			PIC12F675_FLASH_WORDS="$PB_FLASH_WORDS" STRICT_TOOLS=1 "$@"
	}

	run_calibration_make() {
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
			make --no-print-directory -C "$repo" --old-file=pic12f675-simcal \
			pic12f675-test-calibration \
			CC=true HOSTCC=true PIC12F675_BUILD_DIR="$PB_BUILD_DIR" \
			FW_BASE="$PB_FW_BASE" PIC12F675_TAG="$PB_TAG" \
			PIC12F675_FLASH_WORDS="$PB_FLASH_WORDS" STRICT_TOOLS=1 "$@"
	}

	matrix_injector_log="$work/pic12f675-matrix-injector.log"
	matrix_injector="$tools/pic12f675-matrix-injector.py"
	cat > "$matrix_injector" <<'PY'
#!/usr/bin/env python3
import os
import subprocess
import sys

with open(os.environ["MATRIX_INJECTOR_LOG"], "a", encoding="ascii") as stream:
    stream.write(" ".join(sys.argv[1:]) + "\n")
is_probe = sys.argv[-1].endswith(".probe")
published = os.environ.get("MATRIX_REQUIRE_UNPUBLISHED_PATH")
staged = os.environ.get("MATRIX_REQUIRE_STAGED_PATH")
if is_probe and published and os.path.lexists(published):
    print("final matrix evidence was published before calibration", file=sys.stderr)
    sys.exit(98)
if is_probe and staged:
    if not os.path.isfile(staged) or os.path.islink(staged):
        print("staged matrix evidence is unavailable during calibration", file=sys.stderr)
        sys.exit(99)
    verify = subprocess.call([
        sys.executable, os.environ["MATRIX_EVIDENCE_TOOL"], "verify-staged",
        "--build-dir", os.environ["MATRIX_EVIDENCE_BUILD_DIR"],
        "--fw-base", os.environ["MATRIX_EVIDENCE_FW_BASE"],
        "--tag", os.environ["MATRIX_EVIDENCE_TAG"],
    ], stdout=subprocess.DEVNULL)
    if verify != 0:
        print("staged matrix evidence does not verify during calibration",
              file=sys.stderr)
        sys.exit(99)
result = subprocess.call(
    [sys.executable, os.environ["REAL_CAL_INJECTOR"]] + sys.argv[1:])
collision = os.environ.get("MATRIX_PROMOTION_COLLISION_PATH")
if (collision
        and sys.argv[-1].endswith("tq2_l2_5v_relay_simcal.hex.reinjected")):
    with open(collision, "x", encoding="ascii") as stream:
        stream.write("existing promotion destination must survive byte-for-byte")
if (result == 0 and os.environ.get("MATRIX_INJECTOR_NONDETERMINISTIC") == "1"
        and sys.argv[-1].endswith(".probe")):
    with open(sys.argv[-1], "ab") as stream:
        stream.write(b"\n")
    retained = os.environ.get("MATRIX_INJECTOR_MUTATE_PATH")
    if retained:
        with open(retained, "ab") as stream:
            stream.write(b"consumer mutation\n")
        collision = os.environ.get("MATRIX_STAGE_FAILURE_COLLISION_PATH")
        if collision:
            with open(collision, "x", encoding="ascii") as stream:
                stream.write(
                    "existing promotion destination must survive byte-for-byte")
sys.exit(result)
PY

	run_matrix_qualifier() {
		MATRIX_INJECTOR_LOG="$matrix_injector_log" \
		REAL_CAL_INJECTOR="$repo/test/pic/inject_calibration_word.py" \
		MATRIX_INJECTOR_NONDETERMINISTIC="${MATRIX_INJECTOR_NONDETERMINISTIC:-0}" \
		MATRIX_INJECTOR_MUTATE_PATH="${MATRIX_INJECTOR_MUTATE_PATH:-}" \
		MATRIX_REQUIRE_UNPUBLISHED_PATH="$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" \
		MATRIX_REQUIRE_STAGED_PATH="$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json.staged" \
		MATRIX_EVIDENCE_TOOL="$repo/test/pic/pic12f675_matrix_evidence.py" \
		MATRIX_EVIDENCE_BUILD_DIR="$repo/$PB_BUILD_DIR" \
		MATRIX_EVIDENCE_FW_BASE="$PB_FW_BASE" MATRIX_EVIDENCE_TAG="$PB_TAG" \
		MATRIX_PROMOTION_COLLISION_PATH="${MATRIX_PROMOTION_COLLISION_PATH:-}" \
		MATRIX_STAGE_FAILURE_COLLISION_PATH="${MATRIX_STAGE_FAILURE_COLLISION_PATH:-}" \
		FAKE_XC8_PIC12F675_MODE=shipping \
		FAKE_XC8_MODE="${MATRIX_XC8_MODE:-pass}" \
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
			make --no-print-directory -C "$repo" _pic12f675-qualify-matrix \
			CC=true HOSTCC=true PIC_CC="$tools/xc8" \
			PIC12F675_BUILD_DIR="$PB_BUILD_DIR" \
			FW_BASE="$PB_FW_BASE" PIC12F675_TAG="$PB_TAG" \
			PIC12F675_FLASH_WORDS="$PB_FLASH_WORDS" \
			PIC12F675_CAL_INJECTOR="$matrix_injector" STRICT_TOOLS=1
	}

	matrix_lane_log="$work/pic12f675-matrix-lanes.log"
	matrix_lane_make="$tools/pic12f675-matrix-lane-make"
	cat > "$matrix_lane_make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${MATRIX_ENTER_REAL_MAKE:-0}" -eq 1 ]; then
	export MATRIX_ENTER_REAL_MAKE=0
	exec -a "$0" "${REAL_PROJECT_MAKE:?}" "$@"
fi
lane=
	for arg in "$@"; do
		case "$arg" in
			pic12f675-test-fault) lane=fault ;;
			pic12f675-test-lockstep) lane=lockstep ;;
			pic12f675-test-io) lane=io ;;
			pic12f675-test-config|pic12f675-analyze|pic12f675-coverage-check-fw|\
			pic12f675-test-gpsim|pic12f675-test-stack-bound) lane=prehardware ;;
			pic12f675-test-target) lane=target ;;
		esac
		done
	if [ -z "$lane" ]; then
		exec -a "$0" "${REAL_PROJECT_MAKE:?}" "$@"
	fi
	printf '%s\n' "$*" >> "${MATRIX_LANE_LOG:?}"
	case "$lane" in
		fault)
			printf 'FAULT-INJECT PASS: 38 checks, 0 failures\n'
			printf 'PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=cd4053_simple status=pass checks=38 failures=0\n'
			;;
		lockstep)
			printf 'LOCK-STEP PASS: 3005 checks, 0 failures\n'
			printf 'PIC_TARGET_RESULT format=1 device=pic12f675 lane=lockstep variant=cd4053_simple status=pass checks=3005 failures=0\n'
			;;
		io)
			printf 'TARGET-IO PASS: 25 checks, 0 failures\n'
			printf 'PIC_TARGET_RESULT format=1 device=pic12f675 lane=io variant=cd4053_simple status=pass checks=25 failures=0\n'
			;;
		prehardware) printf 'PRE-HARDWARE COMPONENT PASS\n' ;;
		target) printf 'TARGET AGGREGATE PASS\n' ;;
	*) printf 'unexpected matrix lane command: %s\n' "$*" >&2; exit 2 ;;
esac
if [ "$lane" = "${MATRIX_MUTATE_LANE:-none}" ]; then
	printf 'consumer mutation\n' >> "${MATRIX_MUTATE_PATH:?}"
fi
if [ "$lane" = "${MATRIX_FAIL_LANE:-none}" ]; then
	exit 17
fi
EOF
	chmod 750 "$matrix_lane_make"

	run_matrix_target() {
		REAL_PROJECT_MAKE="$real_make" MATRIX_ENTER_REAL_MAKE=1 \
		MATRIX_LANE_LOG="$matrix_lane_log" \
		MATRIX_MUTATE_LANE="${MATRIX_MUTATE_LANE:-none}" \
		MATRIX_MUTATE_PATH="${MATRIX_MUTATE_PATH:-}" \
		MATRIX_FAIL_LANE="${MATRIX_FAIL_LANE:-none}" \
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
			"$matrix_lane_make" --no-print-directory -C "$repo" \
			--old-file=_pic12f675-qualify-matrix pic12f675-test-target \
			MAKE=true PROJECT_MAKE=true CC=true HOSTCC=true \
			PIC12F675_BUILD_DIR="$PB_BUILD_DIR" \
			FW_BASE="$PB_FW_BASE" PIC12F675_TAG="$PB_TAG" \
			PIC12F675_TARGET_VARIANT=cd4053_simple STRICT_TOOLS=1
	}

	run_matrix_combined() {
		REAL_PROJECT_MAKE="$real_make" MATRIX_ENTER_REAL_MAKE=1 \
		MATRIX_INJECTOR_LOG="$matrix_injector_log" \
		REAL_CAL_INJECTOR="$repo/test/pic/inject_calibration_word.py" \
		MATRIX_INJECTOR_NONDETERMINISTIC=0 \
		MATRIX_REQUIRE_UNPUBLISHED_PATH="$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" \
		MATRIX_REQUIRE_STAGED_PATH="$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json.staged" \
		MATRIX_EVIDENCE_TOOL="$repo/test/pic/pic12f675_matrix_evidence.py" \
		MATRIX_EVIDENCE_BUILD_DIR="$repo/$PB_BUILD_DIR" \
		MATRIX_EVIDENCE_FW_BASE="$PB_FW_BASE" MATRIX_EVIDENCE_TAG="$PB_TAG" \
		MATRIX_LANE_LOG="$matrix_lane_log" \
		MATRIX_MUTATE_LANE=none MATRIX_MUTATE_PATH= \
		FAKE_XC8_PIC12F675_MODE=shipping FAKE_XC8_MODE=pass \
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
			"$matrix_lane_make" --no-print-directory -C "$repo" \
			pic12f675-test pic12f675-test-target-variants \
			MAKE=true PROJECT_MAKE=true CC=true HOSTCC=true \
			PIC_CC="$tools/xc8" \
			PIC12F675_BUILD_DIR="$PB_BUILD_DIR" \
			FW_BASE="$PB_FW_BASE" PIC12F675_TAG="$PB_TAG" \
			PIC12F675_FLASH_WORDS="$PB_FLASH_WORDS" \
			PIC12F675_CAL_INJECTOR="$matrix_injector" STRICT_TOOLS=1
	}

	real_config_checker="$tools/test_config_pic12f675"
	cc -std=c11 -O2 -Wall -Wextra -Werror -I"$ROOT/test" \
		-DPIC_DEVICE_NAME='"PIC12F675"' \
		"$ROOT/test/pic/test_config_pic12f675.c" -o "$real_config_checker"
	run_simcal_consumer_make() {
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
			make --no-print-directory -C "$repo" --old-file=pic12f675-simcal "$1" \
			CC=true HOSTCC=true PIC12F675_BUILD_DIR="$PB_BUILD_DIR" \
			FW_BASE="$PB_FW_BASE" PIC12F675_TAG="$PB_TAG" \
			PIC_SOAK_CXX="$tools/missing-cxx" STRICT_TOOLS= "${@:2}"
	}

	# Fail or signal while validating the second image, but only after witnessing
	# the first derived image as a nonempty regular file. This makes the producer
	# cleanup regression non-vacuous: there was a partial publication to remove.
	simcal_validator="$tools/simcal-validator"
	cat > "$simcal_validator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
image=${1:?}
case "$image" in
	*-cd4053_with_mute_simcal.hex)
		[[ -f "${SIMCAL_FIRST_IMAGE:?}" && ! -L "$SIMCAL_FIRST_IMAGE" && -s "$SIMCAL_FIRST_IMAGE" ]] \
			|| { printf 'first simulator image was not published before second-image validation\n' >&2; exit 81; }
		: > "${SIMCAL_FAILURE_MARKER:?}"
		case "${SIMCAL_VALIDATOR_MODE:-fail}" in
			fail)
				printf 'forced second-image validation failure\n' >&2
				exit 82
				;;
			signal)
				kill -TERM "$PPID"
				: > "${SIMCAL_SIGNAL_MARKER:?}"
				sleep 1
				exit 0
				;;
		esac
		;;
esac
exec "${REAL_IHEX_VALIDATOR:?}" "$@"
EOF
	chmod 750 "$simcal_validator"

	for image in "${cal_shipping[@]}"; do write_calibration_fixture "$image"; done
	run_simcal_make >/dev/null
	for image in "${cal_sim[@]}"; do
		[[ -f "$image" && ! -L "$image" && -s "$image" ]] \
			|| { printf 'FAIL: successful PIC12F675 simcal producer omitted %s\n' "$image" >&2; exit 1; }
	done
	checks=$((checks + 1))

	cal_output=$(run_calibration_make)
	[[ "$cal_output" == *"calibration contract holds for all 3 variants"* ]] \
		|| { printf 'FAIL: complete PIC12F675 calibration contract omitted its matrix sentinel: %s\n' \
			"$cal_output" >&2; exit 1; }
	for variant in "${PB_CANONICAL_VARIANTS[@]}"; do
		[ "$(grep -cF "CALIBRATION PASS [$variant]:" <<<"$cal_output")" -eq 1 ] \
			|| { printf 'FAIL: PIC12F675 calibration contract did not check %s exactly once: %s\n' \
				"$variant" "$cal_output" >&2; exit 1; }
	done
	checks=$((checks + 1))

	# One combined Make graph qualifies the retained matrix exactly once, then
	# both aggregates consume it without another producer call. The logged
	# recursive commands also pin every load-bearing --old-file edge.
	: > "$xc8_log"
	: > "$matrix_injector_log"
	: > "$matrix_lane_log"
	matrix_combined_output=$(run_matrix_combined)
	matrix_record=$(python3 "$repo/test/pic/pic12f675_matrix_evidence.py" verify \
		--build-dir "$repo/$PB_BUILD_DIR" --fw-base "$PB_FW_BASE" --tag "$PB_TAG")
	set -- $matrix_record
	[[ "$1" = PIC12F675_MATRIX_SHA256 && "$2" = format=2 && "$#" -eq 14 ]] \
		|| { printf 'FAIL: PIC12F675 matrix identity is not one format-2 twelve-artifact record: %s\n' \
			"$matrix_record" >&2; exit 1; }
	for variant in "${PB_CANONICAL_VARIANTS[@]}"; do
		for prefix in shipping assembly symbols simcal; do
			field="${prefix}_${variant}"
			[[ " $matrix_record " =~ [[:space:]]${field}=[0-9a-f]{64}[[:space:]] ]] \
				|| { printf 'FAIL: PIC12F675 matrix identity omits %s_%s: %s\n' \
					"$prefix" "$variant" "$matrix_record" >&2; exit 1; }
		done
	done
	checks=$((checks + 1))

	# Assembly and symbol sidecars are target-lane inputs, not incidental compiler
	# output. Mutating either must invalidate the same retained identity that the
	# aggregate PASS records expose.
	for sidecar in "${cal_shipping[0]%.hex}.s" "${cal_shipping[0]%.hex}.sym"; do
		sidecar_backup="$work/$(basename "$sidecar").matrix-backup"
		cp -p -- "$sidecar" "$sidecar_backup"
		printf 'sidecar mutation\n' >> "$sidecar"
		if matrix_output=$(python3 "$repo/test/pic/pic12f675_matrix_evidence.py" verify \
				--build-dir "$repo/$PB_BUILD_DIR" --fw-base "$PB_FW_BASE" \
				--tag "$PB_TAG" 2>&1); then
			printf 'FAIL: PIC12F675 matrix oracle accepted changed sidecar %s\n' "$sidecar" >&2
			exit 1
		fi
		[[ "$matrix_output" == *"qualified matrix artifact changed:"* ]] \
			|| { printf 'FAIL: changed PIC12F675 sidecar failed for the wrong reason: %s\n' \
				"$matrix_output" >&2; exit 1; }
		cp -p -- "$sidecar_backup" "$sidecar"
		[ "$(python3 "$repo/test/pic/pic12f675_matrix_evidence.py" verify \
			--build-dir "$repo/$PB_BUILD_DIR" --fw-base "$PB_FW_BASE" \
			--tag "$PB_TAG")" = "$matrix_record" ] \
			|| { printf 'FAIL: restored PIC12F675 sidecar did not restore matrix identity\n' >&2; exit 1; }
	done
	checks=$((checks + 1))

	# Release soak-harness compilation marks this phony producer old. Exercise the
	# exact GNU Make mechanism and prove it cannot invoke XC8 or replace the
	# already-qualified matrix.
	xc8_before_soak_suppression=$(wc -l < "$xc8_log")
	_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
		make --no-print-directory -C "$repo" \
			--old-file=_pic12f675-build-soak _pic12f675-build-soak \
			CC=true HOSTCC=true PIC_CC="$tools/xc8" \
			PIC12F675_BUILD_DIR="$PB_BUILD_DIR" FW_BASE="$PB_FW_BASE" \
			PIC12F675_TAG="$PB_TAG" STRICT_TOOLS=1 >/dev/null
	[[ "$(wc -l < "$xc8_log")" -eq "$xc8_before_soak_suppression" \
		&& "$(python3 "$repo/test/pic/pic12f675_matrix_evidence.py" verify \
			--build-dir "$repo/$PB_BUILD_DIR" --fw-base "$PB_FW_BASE" \
			--tag "$PB_TAG")" = "$matrix_record" ]] \
		|| { printf 'FAIL: --old-file did not preserve the qualified PIC12F675 soak matrix\n' >&2; exit 1; }
	checks=$((checks + 1))
	[[ "$matrix_combined_output" == *"retained matrix qualified: $matrix_record"* \
		&& "$matrix_combined_output" == *"all PIC12F675 pre-hardware checks complete: $matrix_record"* \
		&& "$matrix_combined_output" == *"validated for all variants: $matrix_record"* \
		&& -f "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json.staged" ]] \
		|| { printf 'FAIL: combined PIC12F675 graph omitted retained hash evidence: %s\n' \
			"$matrix_combined_output" >&2; exit 1; }
	[ "$(wc -l < "$xc8_log")" -eq 6 ] \
		|| { printf 'FAIL: combined PIC12F675 graph ran XC8 %s times, expected 6\n' \
			"$(wc -l < "$xc8_log")" >&2; exit 1; }
	[[ "$(wc -l < "$matrix_injector_log")" -eq 10 \
		&& "$(grep -c -- '\.probe' "$matrix_injector_log")" -eq 3 ]] \
		|| { printf 'FAIL: combined PIC12F675 graph changed the exact retained/calibration injection sequence:\n' >&2; \
			cat "$matrix_injector_log" >&2; exit 1; }
	for image in $PB_MATRIX_IMAGES; do
		[ "$(logged_command_count "$xc8_log" "$image")" -eq 2 ] \
			|| { printf 'FAIL: retained/private qualification did not compile %s exactly twice\n' \
				"$image" >&2; exit 1; }
	done
	mapfile -t matrix_calls < "$matrix_lane_log"
	expected_matrix_calls=(
		'--no-print-directory --old-file=pic12f675 pic12f675-test-config'
		'--no-print-directory pic12f675-analyze'
		'--no-print-directory pic12f675-coverage-check-fw'
		'--no-print-directory --old-file=pic12f675-simcal pic12f675-test-gpsim'
		'--no-print-directory --old-file=pic12f675 pic12f675-test-stack-bound'
		'--no-print-directory --old-file=_pic12f675-qualify-matrix PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target'
		'--no-print-directory --old-file=_pic12f675-qualify-matrix PIC12F675_TARGET_VARIANT=cd4053_with_mute pic12f675-test-target'
		'--no-print-directory --old-file=_pic12f675-qualify-matrix PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target'
	)
	[ "${#matrix_calls[@]}" -eq "${#expected_matrix_calls[@]}" ] \
		|| { printf 'FAIL: combined PIC12F675 consumer command count changed\n' >&2; exit 1; }
	for i in "${!expected_matrix_calls[@]}"; do
		[[ "${matrix_calls[$i]}" == "${expected_matrix_calls[$i]}" ]] \
			|| { printf 'FAIL: combined PIC12F675 consumer command %s changed: %s\n' \
				"$i" "${matrix_calls[$i]}" >&2; exit 1; }
	done
	xc8_before_consumer=$(wc -l < "$xc8_log")
	: > "$matrix_lane_log"
	matrix_target_output=$(run_matrix_target)
	mapfile -t matrix_calls < "$matrix_lane_log"
	expected_matrix_calls=(
		'--no-print-directory --old-file=pic12f675-simcal pic12f675-test-fault PIC12F675_FAULT_VARIANT=cd4053_simple'
		'--no-print-directory --old-file=pic12f675-simcal pic12f675-test-lockstep PIC12F675_LOCKSTEP_VARIANT=cd4053_simple'
		'--no-print-directory --old-file=pic12f675-simcal pic12f675-test-io PIC12F675_IO_VARIANT=cd4053_simple'
	)
	[[ "$matrix_target_output" == *"target fault/lock-step/I-O PASS"* \
		&& "$matrix_target_output" == *"$matrix_record"* \
		&& "${#matrix_calls[@]}" -eq "${#expected_matrix_calls[@]}" \
		&& "$(wc -l < "$xc8_log")" -eq "$xc8_before_consumer" ]] \
		|| { printf 'FAIL: PIC12F675 target consumers did not retain one hash-bound matrix: %s\n' \
			"$matrix_target_output" >&2; exit 1; }
	for i in "${!expected_matrix_calls[@]}"; do
		[[ "${matrix_calls[$i]}" == "${expected_matrix_calls[$i]}" ]] \
			|| { printf 'FAIL: PIC12F675 target consumer command %s changed: %s\n' \
				"$i" "${matrix_calls[$i]}" >&2; exit 1; }
	done
	matrix_sentinel='existing promotion destination must survive byte-for-byte'
	if matrix_output=$(MATRIX_PROMOTION_COLLISION_PATH="$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" \
			run_matrix_qualifier 2>&1); then
		printf 'FAIL: PIC12F675 qualifier overwrote a colliding promotion destination\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"matrix evidence already exists"* \
		&& "$(<"$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json")" == "$matrix_sentinel" \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json.staged" ]] \
		|| { printf 'FAIL: promotion collision did not preserve existing evidence exactly: %s\n' \
			"$matrix_output" >&2; exit 1; }
	rm "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json"
	run_matrix_qualifier >/dev/null
	matrix_record=$(python3 "$repo/test/pic/pic12f675_matrix_evidence.py" verify \
		--build-dir "$repo/$PB_BUILD_DIR" --fw-base "$PB_FW_BASE" --tag "$PB_TAG")
	matrix_alias="$work/pic12f675-matrix-alias"
	ln -s "$repo/$PB_BUILD_DIR" "$matrix_alias"
	if matrix_output=$(python3 "$repo/test/pic/pic12f675_matrix_evidence.py" verify \
			--build-dir "$matrix_alias" --fw-base "$PB_FW_BASE" --tag "$PB_TAG" 2>&1); then
		printf 'FAIL: PIC12F675 matrix oracle accepted a symlinked build root\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"build directory is not a non-symlink directory"* ]] \
		|| { printf 'FAIL: symlinked matrix root failed for the wrong reason: %s\n' \
			"$matrix_output" >&2; exit 1; }
	mv "$repo/$PB_BUILD_DIR/simcal" "$repo/$PB_BUILD_DIR/simcal.real"
	ln -s simcal.real "$repo/$PB_BUILD_DIR/simcal"
	if matrix_output=$(python3 "$repo/test/pic/pic12f675_matrix_evidence.py" verify \
			--build-dir "$repo/$PB_BUILD_DIR" --fw-base "$PB_FW_BASE" --tag "$PB_TAG" 2>&1); then
		printf 'FAIL: PIC12F675 matrix oracle accepted a symlinked simcal root\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"simcal directory is not a non-symlink directory"* ]] \
		|| { printf 'FAIL: symlinked simcal root failed for the wrong reason: %s\n' \
			"$matrix_output" >&2; exit 1; }
	rm "$repo/$PB_BUILD_DIR/simcal"
	mv "$repo/$PB_BUILD_DIR/simcal.real" "$repo/$PB_BUILD_DIR/simcal"
	printf 'pre-lane mutation\n' >> "${cal_shipping[0]}"
	: > "$matrix_lane_log"
	if matrix_output=$(run_matrix_target 2>&1); then
		printf 'FAIL: PIC12F675 aggregate accepted stale initial matrix evidence\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"qualified matrix artifact changed: shipping_cd4053_simple"* \
		&& ! -s "$matrix_lane_log" \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" ]] \
		|| { printf 'FAIL: stale initial matrix evidence was not invalidated: %s\n' \
			"$matrix_output" >&2; exit 1; }
	checks=$((checks + 1))

	# A compiler that changes one private witness image must fail qualification
	# before any consumer and invalidate the manifest.
	: > "$matrix_lane_log"
	if matrix_output=$(MATRIX_XC8_MODE=nondeterministic-private \
			run_matrix_qualifier 2>&1); then
		printf 'FAIL: PIC12F675 qualifier accepted nondeterministic compiler output\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"private compiler witness changed image shipping_cd4053_simple"* \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json.staged" \
		&& ! -s "$matrix_lane_log" ]] \
		|| { printf 'FAIL: nondeterministic compiler failed for the wrong reason: %s\n' \
			"$matrix_output" >&2; exit 1; }
	checks=$((checks + 1))

	# The retained derivation and calibration probe must be byte-identical. First
	# reject probe-only nondeterminism while the staged matrix remains unchanged.
	if matrix_output=$(MATRIX_INJECTOR_NONDETERMINISTIC=1 \
			run_matrix_qualifier 2>&1); then
		printf 'FAIL: PIC12F675 qualifier accepted nondeterministic injection\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"injection is not deterministic"* \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json.staged" ]] \
		|| { printf 'FAIL: nondeterministic injector failed for the wrong reason: %s\n' \
			"$matrix_output" >&2; exit 1; }

	# Also mutate a retained simulator image while that failing calibration runs.
	# The post-failure verifier must reject it before replaying the lane output.
	if matrix_output=$(MATRIX_INJECTOR_NONDETERMINISTIC=1 \
			MATRIX_INJECTOR_MUTATE_PATH="${cal_sim[0]}" \
			MATRIX_STAGE_FAILURE_COLLISION_PATH="$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" \
			run_matrix_qualifier 2>&1); then
		printf 'FAIL: PIC12F675 qualifier accepted nondeterministic injection\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"qualified matrix artifact changed: simcal_cd4053_simple"* \
		&& "$matrix_output" != *"injection is not deterministic"* \
		&& "$(<"$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json")" \
			== 'existing promotion destination must survive byte-for-byte' \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json.staged" ]] \
		|| { printf 'FAIL: failed calibration did not recheck its retained matrix: %s\n' \
			"$matrix_output" >&2; exit 1; }
	rm "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json"
	checks=$((checks + 1))

	# Requalify, then let the first failing fake consumer alter a retained shipping
	# image. Verification must run despite the lane failure, stop lock-step/I/O,
	# and remove evidence that no longer describes the bytes on disk.
	: > "$matrix_lane_log"
	run_matrix_qualifier >/dev/null
	mutated_matrix_image="${cal_shipping[0]}"
	if matrix_output=$(MATRIX_MUTATE_LANE=fault MATRIX_FAIL_LANE=fault \
		MATRIX_MUTATE_PATH="$mutated_matrix_image" run_matrix_target 2>&1); then
		printf 'FAIL: PIC12F675 aggregate accepted a consumer-mutated matrix\n' >&2
		exit 1
	fi
	[[ "$matrix_output" == *"qualified matrix artifact changed: shipping_cd4053_simple"* \
		&& "$matrix_output" != *"FAULT-INJECT PASS"* \
		&& "$(wc -l < "$matrix_lane_log")" -eq 1 \
		&& ! -e "$repo/$PB_BUILD_DIR/.pic12f675-qualified-matrix.json" ]] \
		|| { printf 'FAIL: consumer matrix mutation failed for the wrong reason: %s\n' \
			"$matrix_output" >&2; exit 1; }
	checks=$((checks + 1))
	# Restore a coherent retained fixture for the simcal publication probes
	# below; the mutation check intentionally left one shipping file malformed
	# after EOF.
	run_matrix_qualifier >/dev/null

	config_overlap="$work/config-overlap.hex"
	printf '%s\n' ':040000000028FF23B2' ':02400E00CC31B3' \
		':02400E00CC31B3' ':00000001FF' > "$config_overlap"
	if config_output=$("$real_config_checker" "$config_overlap" 2>&1); then
		printf 'FAIL: PIC12F675 CONFIG checker accepted a duplicate CONFIG definition\n' >&2
		exit 1
	fi
	[[ "$config_output" == *"duplicate CONFIG byte address"* ]] \
		|| { printf 'FAIL: duplicate CONFIG definition failed for the wrong reason: %s\n' \
			"$config_output" >&2; exit 1; }
	checks=$((checks + 1))

	# A representative partial set must fail the calibration contract itself,
	# even when its producer prerequisite is deliberately suppressed.
	rm -f "${cal_sim[2]}"
	if cal_output=$(run_calibration_make 2>&1); then
		printf 'FAIL: PIC12F675 calibration contract accepted a partial simulator-image matrix\n' >&2
		exit 1
	fi
	[[ "$cal_output" == *"simulator image matrix is partial"* ]] \
		|| { printf 'FAIL: partial PIC12F675 calibration matrix produced the wrong result: %s\n' \
			"$cal_output" >&2; exit 1; }
	checks=$((checks + 1))

	# The libgpsim consumers arrived after the original finding. They must apply
	# the same matrix oracle before their optional C++/header skips, or a
	# suppressed producer could let one selected image stand in for the matrix.
	# Every simulator lane for this part belongs here; the soak joined them last.
	for target in pic12f675-test-io pic12f675-test-lockstep pic12f675-test-fault \
			pic12f675-test-soak; do
		if cal_output=$(run_simcal_consumer_make "$target" 2>&1); then
			printf 'FAIL: %s accepted a partial PIC12F675 simulator-image matrix\n' "$target" >&2
			exit 1
		fi
		[[ "$cal_output" == *"simulator image matrix is partial"* \
			&& "$cal_output" != *"no C++ compiler"* ]] \
			|| { printf 'FAIL: %s did not validate the image matrix before its tool skip: %s\n' \
				"$target" "$cal_output" >&2; exit 1; }
		checks=$((checks + 1))
	done

	# Fail while validating the second output after the first derived image was
	# witnessed. The producer trap must remove the complete expected set, not
	# leave that prefix.
	for image in "${cal_shipping[@]}"; do write_calibration_fixture "$image"; done
	simcal_failure_marker="$work/simcal-second-image-validated"
	rm -f "$simcal_failure_marker"
	export SIMCAL_FIRST_IMAGE="${cal_sim[0]}" \
		SIMCAL_FAILURE_MARKER="$simcal_failure_marker" \
		REAL_IHEX_VALIDATOR="$repo/scripts/validate-ihex.sh" \
		SIMCAL_VALIDATOR_MODE=fail
	if cal_output=$(run_simcal_make "IHEX_VALIDATOR=$simcal_validator" 2>&1); then
		printf 'FAIL: PIC12F675 simcal producer accepted a forced second-image validation failure\n' >&2
		exit 1
	fi
	[[ -f "$simcal_failure_marker" && "$cal_output" == *"forced second-image validation failure"* ]] \
		|| { printf 'FAIL: failed PIC12F675 simcal producer reported the wrong injection error: %s\n' \
			"$cal_output" >&2; exit 1; }
	for image in "${cal_sim[@]}"; do
		[[ ! -e "$image" && ! -L "$image" ]] \
			|| { printf 'FAIL: failed PIC12F675 simcal producer left partial image %s\n' "$image" >&2; exit 1; }
	done
	checks=$((checks + 1))

	# The same mid-matrix point interrupted by SIGTERM must be a nonzero target
	# result and must clean every expected output even if the shell entered its
	# signal trap with a prior command status of zero.
	rm -f "$simcal_failure_marker"
	simcal_signal_marker="$work/simcal-signal-delivered"
	rm -f "$simcal_signal_marker"
	export SIMCAL_VALIDATOR_MODE=signal SIMCAL_SIGNAL_MARKER="$simcal_signal_marker"
	if cal_output=$(run_simcal_make "IHEX_VALIDATOR=$simcal_validator" 2>&1); then
		printf 'FAIL: interrupted PIC12F675 simcal producer exited successfully\n' >&2
		exit 1
	fi
	[[ -f "$simcal_failure_marker" && -f "$simcal_signal_marker" ]] \
		|| { printf 'FAIL: PIC12F675 simcal signal fixture did not reach second-image validation\n' >&2; exit 1; }
	for image in "${cal_sim[@]}"; do
		[[ ! -e "$image" && ! -L "$image" ]] \
			|| { printf 'FAIL: interrupted PIC12F675 simcal producer left image %s\n' "$image" >&2; exit 1; }
	done
	checks=$((checks + 1))
	unset SIMCAL_FIRST_IMAGE SIMCAL_FAILURE_MARKER REAL_IHEX_VALIDATOR \
		SIMCAL_VALIDATOR_MODE SIMCAL_SIGNAL_MARKER

	# An unregistered simulator image prevents successful publication. Expected
	# products are cleaned as a set; the unknown file is reported, not deleted.
	for image in "${cal_shipping[@]}"; do write_calibration_fixture "$image"; done
	mkdir -p "$(dirname "$cal_extra")"
	printf ':00000001FF\n' > "$cal_extra"
	if cal_output=$(run_simcal_make 2>&1); then
		printf 'FAIL: PIC12F675 simcal producer accepted an unexpected derived image\n' >&2
		exit 1
	fi
	[[ "$cal_output" == *"unexpected PIC12F675 simulator image outside the exact matrix"* \
		&& -f "$cal_extra" ]] \
		|| { printf 'FAIL: unexpected PIC12F675 simulator image produced the wrong publication result: %s\n' \
			"$cal_output" >&2; exit 1; }
	for image in "${cal_sim[@]}"; do
		[[ ! -e "$image" && ! -L "$image" ]] \
			|| { printf 'FAIL: rejected PIC12F675 simcal publication left expected image %s\n' "$image" >&2; exit 1; }
	done
	checks=$((checks + 1))

	# No shipping images is the one accepted incomplete state: the normal local
	# no-XC8 skip remains zero, while STRICT_TOOLS turns the same condition into a
	# failure. Both paths remove stale expected derived images. The local path must
	# classify zero images before probing Python; otherwise a host missing both XC8
	# and Python fails instead of taking the documented skip.
	rm -f "$cal_extra" "${cal_shipping[@]}" "${cal_sim[@]}"
	mkdir -p "$(dirname "${cal_sim[0]}")"
	write_calibration_fixture "${cal_sim[0]}"
	if ! cal_output=$(run_simcal_make STRICT_TOOLS= 2>&1); then
		printf 'FAIL: PIC12F675 simcal producer rejected its zero-image local skip: %s\n' "$cal_output" >&2
		exit 1
	fi
	[[ "$cal_output" == *"skipping calibration injection"* ]] \
		|| { printf 'FAIL: PIC12F675 simcal zero-image skip reported the wrong result: %s\n' \
			"$cal_output" >&2; exit 1; }
	for image in "${cal_sim[@]}"; do
		[[ ! -e "$image" && ! -L "$image" ]] \
			|| { printf 'FAIL: PIC12F675 simcal zero-image skip left %s\n' "$image" >&2; exit 1; }
	done
	checks=$((checks + 1))

	mkdir -p "$(dirname "${cal_sim[0]}")"
	write_calibration_fixture "${cal_sim[0]}"
	if ! cal_output=$(run_simcal_make STRICT_TOOLS= \
			"PIC12F675_PYTHON=$tools/missing-python" 2>&1); then
		printf 'FAIL: PIC12F675 zero-XC8 simcal path required Python before skipping: %s\n' \
			"$cal_output" >&2
		exit 1
	fi
	[[ "$cal_output" == *"skipping calibration injection"* \
		&& "$cal_output" != *"required by the PIC12F675 calibration-word injector"* ]] \
		|| { printf 'FAIL: PIC12F675 zero-XC8/missing-Python skip reported the wrong result: %s\n' \
			"$cal_output" >&2; exit 1; }
	for image in "${cal_sim[@]}"; do
		[[ ! -e "$image" && ! -L "$image" ]] \
			|| { printf 'FAIL: zero-XC8/missing-Python skip left %s\n' "$image" >&2; exit 1; }
	done
	checks=$((checks + 1))

	mkdir -p "$(dirname "${cal_sim[0]}")"
	write_calibration_fixture "${cal_sim[0]}"
	if cal_output=$(run_simcal_make 2>&1); then
		printf 'FAIL: PIC12F675 simcal producer accepted zero shipping images under STRICT_TOOLS=1\n' >&2
		exit 1
	fi
	[[ "$cal_output" == *"STRICT_TOOLS=1:"* ]] \
		|| { printf 'FAIL: strict PIC12F675 simcal zero-image failure reported the wrong result: %s\n' \
			"$cal_output" >&2; exit 1; }
	for image in "${cal_sim[@]}"; do
		[[ ! -e "$image" && ! -L "$image" ]] \
			|| { printf 'FAIL: strict PIC12F675 simcal zero-image failure left %s\n' "$image" >&2; exit 1; }
	done
	checks=$((checks + 1))

	# Python is still mandatory once shipping images exist. A reordered probe must
	# not turn authoritative calibration work into a skip.
	for image in "${cal_shipping[@]}"; do write_calibration_fixture "$image"; done
	if cal_output=$(run_simcal_make STRICT_TOOLS= \
			"PIC12F675_PYTHON=$tools/missing-python" 2>&1); then
		printf 'FAIL: PIC12F675 simcal accepted missing Python with shipping images present\n' >&2
		exit 1
	fi
	[[ "$cal_output" == *"required by the PIC12F675 calibration-word injector"* ]] \
		|| { printf 'FAIL: PIC12F675 shipping-image/missing-Python failure reported the wrong result: %s\n' \
			"$cal_output" >&2; exit 1; }
	checks=$((checks + 1))
fi

[ -z "$expected_checks" ] || [ "$checks" -eq "$expected_checks" ] \
	|| { printf 'FAIL: canonical %s build validation ran %d checks, expected %d\n' \
		"$PB_TARGET" "$checks" "$expected_checks" >&2; exit 1; }
printf '%s build validation: %d checks, 0 failures\n' "$PB_LABEL" "$checks"
