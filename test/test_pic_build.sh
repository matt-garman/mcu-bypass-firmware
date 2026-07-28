#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
xc8_log="$work/xc8.log"
host_cc_log="$work/host-cc.log"
host_run_log="$work/host-run.log"
# Parameterized so ONE fake-XC8 regression covers both PIC targets (§4 FOLD).
# Defaults reproduce the PIC10F322 run exactly, so `make test-pic-build` is
# unchanged; the PIC10F320 lane re-invokes with the PB_* overrides.
PB_LABEL=${PB_LABEL:-PIC}
PB_TARGET=${PB_TARGET:-pic}
PB_CC_VAR=${PB_CC_VAR:-PIC_CC}
PB_BUILD_DIR_VAR=${PB_BUILD_DIR_VAR:-PIC_BUILD_DIR}
PB_BUILD_DIR=${PB_BUILD_DIR:-build_pic}
PB_FW_BASE_VAR=${PB_FW_BASE_VAR:-FW_BASE}
PB_FW_BASE=${PB_FW_BASE:-bypass}
PB_TAG_VAR=${PB_TAG_VAR:-PIC_TAG}
PB_TAG=${PB_TAG:-pic10f322}
PB_FLASH_VAR=${PB_FLASH_VAR:-PIC_FLASH_WORDS}
PB_FLASH_WORDS=${PB_FLASH_WORDS:-512}
PB_VARIANT_VAR=${PB_VARIANT_VAR:-VARIANTS}
PB_VARIANT=${PB_VARIANT:-cd4053}
# The all-variant build target, and the images it must produce. `pic` builds the
# whole VARIANTS matrix in one invocation; the PIC10F320 lane splits that into
# per-variant `pic320` plus the `pic320-variants` aggregate, so the matrix checks
# below point at whichever target owns the matrix for this chip.
PB_MATRIX_TARGET=${PB_MATRIX_TARGET:-pic}
PB_MATRIX_VARIANTS_VAR=${PB_MATRIX_VARIANTS_VAR:-VARIANTS}
PB_MATRIX_VARIANTS=${PB_MATRIX_VARIANTS:-cd4053 mute relay}
PB_MATRIX_IMAGES=${PB_MATRIX_IMAGES:-bypass_cd4053_pic10f322.hex bypass_mute_pic10f322.hex bypass_relay_pic10f322.hex}
PB_MATRIX_FAIL_IMAGE=${PB_MATRIX_FAIL_IMAGE:-bypass_relay_pic10f322.hex}
PB_MATRIX_REQUIRE_COMPLETE=${PB_MATRIX_REQUIRE_COMPLETE:-1}
PB_MATRIX_UNSUPPORTED=${PB_MATRIX_UNSUPPORTED:-unknown}
PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-}
PB_SELECTOR_ROUTING=${PB_SELECTOR_ROUTING:-0}
PB_SIZE_TARGET=${PB_SIZE_TARGET:-}
PB_STACK_TARGET=${PB_STACK_TARGET:-pic-test-stack-bound}
PB_STACK_DEVICE_VAR=${PB_STACK_DEVICE_VAR:-PIC_DEVICE_INI}
PB_RETURN_STACK_REQUIRED=${PB_RETURN_STACK_REQUIRED:-0}
PB_REBUILD_REQUIRED=${PB_REBUILD_REQUIRED:-0}
product_override_args=()
case "$PB_TARGET" in
	pic)
		[ "$PB_LABEL" = PIC ] \
			|| { printf 'FAIL: canonical pic build validation requires PB_LABEL=PIC\n' >&2; exit 1; }
		PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-$PB_MATRIX_VARIANTS}
		product_override_args=(PIC_HEXES= PIC_ASSEMBLIES= PIC_SYMBOLS= PIC_BUILD_PRODUCTS=)
		expected_checks=36
		;;
	pic320)
		[ "$PB_LABEL" = PIC10F320 ] \
			|| { printf 'FAIL: canonical pic320 build validation requires PB_LABEL=PIC10F320\n' >&2; exit 1; }
		[ "$PB_REBUILD_REQUIRED" = 1 ] \
			|| { printf 'FAIL: canonical pic320 build validation requires PB_REBUILD_REQUIRED=1\n' >&2; exit 1; }
		PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-$PB_VARIANT}
		product_override_args=(PIC320_HEX= PIC320_ASM= PIC320_SYM= PIC320_BUILD_PRODUCTS=)
		expected_checks=71
		;;
	*) PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-$PB_VARIANT}; expected_checks= ;;
esac
hex="$repo/$PB_BUILD_DIR/${PB_FW_BASE}_${PB_VARIANT}_${PB_TAG}.hex"
asm=${hex%.hex}.s
sym=${hex%.hex}.sym
size_probe_stem="$repo/$PB_BUILD_DIR/size_probe_$PB_VARIANT"
checks=0
unset FAKE_XC8_MODE FAKE_XC8_FAIL_NAME FAKE_XC8_SIGNAL_MARKER \
	MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
mkdir -p "$repo/src" "$repo/scripts" "$repo/test/pic10f320/equiv" \
	"$repo/test/pic10f320/actuation" "$repo/test/pic10f320/fault" \
	"$repo/build_pic" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$repo/scripts/validate-ihex.sh"
cp "$ROOT/test/check_stack_depth_pic.sh" "$repo/test/check_stack_depth_pic.sh"
cp "$ROOT/test/pic10f320/return_stack_oracle.py" \
	"$repo/test/pic10f320/return_stack_oracle.py"
: > "$xc8_log"
: > "$host_cc_log"
: > "$host_run_log"
export FAKE_XC8_LOG="$xc8_log"

cat > "$tools/xc8" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
write_valid_hex() {
	printf '%s\n' \
		':020000000028D6' \
		':02400E009E38DA' \
		':00000001FF'
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
	printf '_ctx_ 005D\n' > "${out%.hex}.sym"
}
out=
args=$*
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
printf '%s\t%s\n' "$out" "$args" >> "${FAKE_XC8_LOG:?}"
mode=${FAKE_XC8_MODE:-pass}
case "$mode" in
	no-summary) ;;
	over-budget) printf 'Program space used (513)\n' ;;
	huge-count) printf 'Program space used (9999999999999999999999999999999999999999)\n' ;;
	leading-count) printf 'Program space used (00042)\n' ;;
	*) printf 'Program space used (42)\n' ;;
esac
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
chmod 750 "$tools/xc8" "$tools/host-cc" "$repo/scripts/validate-ihex.sh"
cat > "$tools/noop-oracle.py" <<'EOF'
#!/usr/bin/env python3
raise SystemExit(0)
EOF
chmod 640 "$tools/noop-oracle.py"
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
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_pic10f322.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h src/bypass_output_cd4053_simple.c
	src/bypass_output_cd4053_with_mute.c src/bypass_output_tq2_l2_5v_relay.c
	src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h
	src/bypass_output_tq2_l2_5v_relay.h
	# PIC10F320's shell is self-contained -- it includes no src/ header -- but
	# the `pic320` rule still needs its source to exist. Harmless for the
	# PIC10F322 leg, which never compiles it.
	src/bypass_mcu_pic10f320.c
	test/pic10f320/equiv/fw_harness.c
	test/pic10f320/equiv/test_equiv.c
	test/pic10f320/actuation/test_actuation.c
	test/pic10f320/fault/fw_fault_harness.c
	test/pic10f320/fault/test_fault.c
)
for file in "${files[@]}"; do : > "$repo/$file"; done

run_make() {
	make --no-print-directory -C "$repo" "$PB_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" \
		"$PB_VARIANT_VAR=$PB_BUILD_VARIANTS" STRICT_TOOLS=1 AWK=awk "$@"
}

run_pic320_host_make() {
	local target=$1
	shift
	FAKE_HOST_CC_LOG="$host_cc_log" FAKE_HOST_RUN_LOG="$host_run_log" \
		make --no-print-directory -C "$repo" "$target" \
			CC=true HOSTCC=true PIC320_HOST_CC="$tools/host-cc" \
			PIC320_BUILD_DIR="$PB_BUILD_DIR" PIC320_VARIANT="$PB_VARIANT" "$@"
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

run_stack_make() {
	make --no-print-directory -C "$repo" "$PB_STACK_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" \
		"$PB_VARIANT_VAR=$PB_VARIANT" \
		"$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS" \
		"$PB_STACK_DEVICE_VAR=8" STACK_DEPTH_GATE=./test/check_stack_depth_pic.sh \
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

run_make >/dev/null
"$repo/scripts/validate-ihex.sh" "$hex"
for sidecar in "$asm" "$sym"; do
	[[ -f "$sidecar" && ! -L "$sidecar" && -s "$sidecar" ]] \
		|| { printf 'FAIL: successful %s build did not retain fresh sidecar %s\n' \
			"$PB_LABEL" "$sidecar" >&2; exit 1; }
done
checks=$((checks + 1))

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
		"PIC320_RETURN_STACK_ORACLE=$tools/noop-oracle.py"

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
		"a depth-9 image with PIC320_RETURN_STACK_LIMIT=99" bad-depth \
		PIC320_RETURN_STACK_LIMIT=99
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

(export FAKE_XC8_MODE=leading-count; run_make $PB_FLASH_VAR=000512) >/dev/null
"$repo/scripts/validate-ihex.sh" "$hex"
checks=$((checks + 1))

printf 'stale image\n' > "$hex"
if (export FAKE_XC8_MODE=over-budget; \
		run_make $PB_FLASH_VAR=000512) >/dev/null 2>&1; then
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
	if [ "$PB_TARGET" = pic ]; then
		eval_marker="$work/pic-matrix-make-function-executed"
		rm -f "$eval_marker"
		malicious_matrix='$(eval override CLASSIC_VARIANTS_SUPPORTED:=unknown)$(shell touch '"$eval_marker"')unknown'
		expect_build_matrix_rejected \
			"a recursively self-whitelisting unsupported name" \
			"$malicious_matrix" \
			"$PB_MATRIX_VARIANTS_VAR contains unsupported names"
		[[ ! -e "$eval_marker" ]] \
			|| { printf 'FAIL: PIC matrix text executed a GNU Make function\n' >&2; exit 1; }
	fi
fi

if (export FAKE_XC8_FAIL_NAME="$PB_MATRIX_FAIL_IMAGE"; \
		run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS") >/dev/null 2>&1; then
	printf 'FAIL: late %s variant compiler failure was accepted\n' "$PB_LABEL" >&2
	exit 1
fi
assert_no_matrix_products "late $PB_LABEL matrix compiler failure"
checks=$((checks + 1))

# PIC10F320's target/soak lanes have selectors separate from PIC320_VARIANT.
# Each selector must control the image rebuilt by the pic320 prerequisite, even
# when a caller supplies a conflicting PIC320_VARIANT that names a stale image.
if [ "$PB_SELECTOR_ROUTING" -eq 1 ]; then
	selected=tq2-relay
	selected_hex="$repo/$PB_BUILD_DIR/${PB_FW_BASE}_${selected}_${PB_TAG}.hex"
	selector_specs=(
		"pic320-test-fault-target PIC320_FAULT_VARIANT"
		"pic320-test-lockstep PIC320_LOCKSTEP_VARIANT"
		"pic320-test-io PIC320_IO_VARIANT"
		"pic320-test-soak PIC320_SOAK_VARIANT"
	)
	for spec in "${selector_specs[@]}"; do
		read -r target selector <<<"$spec"
		rm -f "$hex" "$selected_hex"
		if ! make --no-print-directory -C "$repo" "$target" \
				CC=true HOSTCC=true PIC320_CC="$tools/xc8" \
				PIC320_BUILD_DIR="$PB_BUILD_DIR" PIC320_FW_BASE="$PB_FW_BASE" \
				PIC320_TAG="$PB_TAG" PIC320_FLASH_WORDS="$PB_FLASH_WORDS" \
				PIC320_VARIANT="$PB_VARIANT" "$selector=$selected" \
				PIC320_SOAK_CXX="$tools/missing-cxx" STRICT_TOOLS= AWK=awk \
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
fi

if [ -n "$PB_SIZE_TARGET" ]; then
	size_output=$(run_size_make)
	[[ "$size_output" == *"Program space"* ]] \
		|| { printf 'FAIL: PIC size target did not print its memory summary\n' >&2; exit 1; }
	assert_no_size_probe
	checks=$((checks + 1))

	for mode in fail missing empty bad-checksum eof-only trailing symlink directory no-summary; do
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
	: > "$repo/pic320"

	run_make >/dev/null
	[[ "$(logged_command_count "$xc8_log" "$image_output")" -eq $((image_count + 2)) ]] \
		|| { printf 'FAIL: identical PIC10F320 request reused a stale image\n' >&2; exit 1; }
	latest=$(latest_logged_command "$xc8_log" "$image_output")
	command_has_arg "$latest" '-D_XTAL_FREQ=2000000UL' \
		&& command_has_arg "$latest" '-DOUTPUT_CD4053_SIMPLE' \
		|| { printf 'FAIL: repeated PIC10F320 request used stale flags\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_make PIC320_XTAL=4000000UL >/dev/null
	[[ "$(logged_command_count "$xc8_log" "$image_output")" -eq $((image_count + 3)) ]] \
		|| { printf 'FAIL: changed PIC320_XTAL did not invoke XC8 exactly once\n' >&2; exit 1; }
	latest=$(latest_logged_command "$xc8_log" "$image_output")
	command_has_arg "$latest" '-D_XTAL_FREQ=4000000UL' \
		&& ! command_has_arg "$latest" '-D_XTAL_FREQ=2000000UL' \
		|| { printf 'FAIL: changed PIC320_XTAL did not reach the current XC8 invocation\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_make >/dev/null
	[[ "$(logged_command_count "$xc8_log" "$image_output")" -eq $((image_count + 4)) ]] \
		|| { printf 'FAIL: restored PIC320_XTAL did not invoke XC8 exactly once\n' >&2; exit 1; }
	latest=$(latest_logged_command "$xc8_log" "$image_output")
	command_has_arg "$latest" '-D_XTAL_FREQ=2000000UL' \
		&& ! command_has_arg "$latest" '-D_XTAL_FREQ=4000000UL' \
		|| { printf 'FAIL: restored PIC320_XTAL did not reach the current XC8 invocation\n' >&2; exit 1; }
	checks=$((checks + 1))

	equiv_outputs=(
		"$PB_BUILD_DIR/fw_harness.o"
		"$PB_BUILD_DIR/test_equiv_drv.o"
		"$PB_BUILD_DIR/bypass_pure_equiv.o"
		"$PB_BUILD_DIR/test_equiv"
	)
	run_pic320_host_make pic320-test-equiv >/dev/null
	assert_host_output_counts 1 'initial pic320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 1 'initial pic320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	checks=$((checks + 1))
	: > "$repo/pic320-test-equiv"
	run_pic320_host_make pic320-test-equiv >/dev/null
	assert_host_output_counts 2 'identical pic320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 2 'identical pic320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	checks=$((checks + 1))

	run_pic320_host_make pic320-test-equiv PIC320_VARIANT=cd4053-mute >/dev/null
	assert_host_output_counts 3 'changed-variant pic320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 3 'changed-variant pic320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	latest=$(latest_logged_command "$host_cc_log" "$PB_BUILD_DIR/fw_harness.o")
	command_has_arg "$latest" '-DOUTPUT_CD4053_WITH_MUTE' \
		&& ! command_has_arg "$latest" '-DOUTPUT_CD4053_SIMPLE' \
		|| { printf 'FAIL: changed PIC320_VARIANT did not reach the current shared harness compile\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_pic320_host_make pic320-test-equiv >/dev/null
	assert_host_output_counts 4 'restored-variant pic320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 4 'restored-variant pic320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	latest=$(latest_logged_command "$host_cc_log" "$PB_BUILD_DIR/fw_harness.o")
	command_has_arg "$latest" '-DOUTPUT_CD4053_SIMPLE' \
		&& ! command_has_arg "$latest" '-DOUTPUT_CD4053_WITH_MUTE' \
		|| { printf 'FAIL: restored PIC320_VARIANT did not reach the current shared harness compile\n' >&2; exit 1; }
	checks=$((checks + 1))

	run_pic320_host_make pic320-test-equiv \
		PIC320_HOST_CFLAGS='-std=c11 -O0 -DPB_HOST_FLAGS_CHANGED' >/dev/null
	assert_host_output_counts 5 'changed-flags pic320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 5 'changed-flags pic320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	for output in "$PB_BUILD_DIR/test_equiv_drv.o" "$PB_BUILD_DIR/bypass_pure_equiv.o"; do
		latest=$(latest_logged_command "$host_cc_log" "$output")
		command_has_arg "$latest" '-DPB_HOST_FLAGS_CHANGED' \
			&& command_has_arg "$latest" '-O0' \
			|| { printf 'FAIL: changed PIC320_HOST_CFLAGS did not reach current compile for %s\n' \
				"$output" >&2; exit 1; }
	done
	checks=$((checks + 1))

	run_pic320_host_make pic320-test-equiv >/dev/null
	assert_host_output_counts 6 'restored-flags pic320-test-equiv request' "${equiv_outputs[@]}"
	assert_host_run_count 6 'restored-flags pic320-test-equiv request' "$PB_BUILD_DIR/test_equiv"
	for output in "$PB_BUILD_DIR/test_equiv_drv.o" "$PB_BUILD_DIR/bypass_pure_equiv.o"; do
		latest=$(latest_logged_command "$host_cc_log" "$output")
		command_has_arg "$latest" '-O2' \
			&& command_has_arg "$latest" '-Wall' \
			&& command_has_arg "$latest" '-Wextra' \
			&& command_has_arg "$latest" '-Werror' \
			&& ! command_has_arg "$latest" '-DPB_HOST_FLAGS_CHANGED' \
			|| { printf 'FAIL: restored PIC320_HOST_CFLAGS did not reach current compile for %s\n' \
				"$output" >&2; exit 1; }
	done
	checks=$((checks + 1))

	actuation_outputs=(
		"$PB_BUILD_DIR/fw_harness_$PB_VARIANT.o"
		"$PB_BUILD_DIR/test_actuation_drv_$PB_VARIANT.o"
		"$PB_BUILD_DIR/test_actuation_$PB_VARIANT"
	)
	run_pic320_host_make pic320-test-actuation >/dev/null
	assert_host_output_counts 1 'initial pic320-test-actuation request' "${actuation_outputs[@]}"
	assert_host_run_count 1 'initial pic320-test-actuation request' \
		"$PB_BUILD_DIR/test_actuation_$PB_VARIANT"
	checks=$((checks + 1))
	: > "$repo/pic320-test-actuation"
	run_pic320_host_make pic320-test-actuation >/dev/null
	assert_host_output_counts 2 'identical pic320-test-actuation request' "${actuation_outputs[@]}"
	assert_host_run_count 2 'identical pic320-test-actuation request' \
		"$PB_BUILD_DIR/test_actuation_$PB_VARIANT"
	checks=$((checks + 1))

	fault_outputs=(
		"$PB_BUILD_DIR/fw_fault_harness.o"
		"$PB_BUILD_DIR/test_fault_drv.o"
		"$PB_BUILD_DIR/test_fault"
	)
	run_pic320_host_make pic320-test-fault-host >/dev/null
	assert_host_output_counts 1 'initial pic320-test-fault-host request' "${fault_outputs[@]}"
	assert_host_run_count 1 'initial pic320-test-fault-host request' "$PB_BUILD_DIR/test_fault"
	checks=$((checks + 1))
	: > "$repo/pic320-test-fault-host"
	run_pic320_host_make pic320-test-fault-host >/dev/null
	assert_host_output_counts 2 'identical pic320-test-fault-host request' "${fault_outputs[@]}"
	assert_host_run_count 2 'identical pic320-test-fault-host request' "$PB_BUILD_DIR/test_fault"
	checks=$((checks + 1))
fi

[ -z "$expected_checks" ] || [ "$checks" -eq "$expected_checks" ] \
	|| { printf 'FAIL: canonical %s build validation ran %d checks, expected %d\n' \
		"$PB_TARGET" "$checks" "$expected_checks" >&2; exit 1; }
printf '%s build validation: %d checks, 0 failures\n' "$PB_LABEL" "$checks"
