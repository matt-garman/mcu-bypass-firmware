#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
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
PB_MATRIX_REQUIRE_COMPLETE=${PB_MATRIX_REQUIRE_COMPLETE:-0}
PB_MATRIX_UNSUPPORTED=${PB_MATRIX_UNSUPPORTED:-unknown}
PB_SELECTOR_ROUTING=${PB_SELECTOR_ROUTING:-0}
PB_SIZE_TARGET=${PB_SIZE_TARGET:-}
PB_RETURN_STACK_REQUIRED=${PB_RETURN_STACK_REQUIRED:-0}
hex="$repo/$PB_BUILD_DIR/${PB_FW_BASE}_${PB_VARIANT}_${PB_TAG}.hex"
size_probe_stem="$repo/$PB_BUILD_DIR/size_probe_$PB_VARIANT"
checks=0
unset FAKE_XC8_MODE FAKE_XC8_FAIL_NAME FAKE_XC8_SIGNAL_MARKER \
	MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
mkdir -p "$repo/src" "$repo/scripts" "$repo/test/pic10f320" \
	"$repo/build_pic" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$repo/scripts/validate-ihex.sh"
cp "$ROOT/test/pic10f320/return_stack_oracle.py" \
	"$repo/test/pic10f320/return_stack_oracle.py"

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
out=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
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
	fail) printf 'partial image\n' > "$out"; exit 1 ;;
	missing) : ;;
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
chmod 750 "$tools/xc8" "$repo/scripts/validate-ihex.sh"
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
)
for file in "${files[@]}"; do : > "$repo/$file"; done

run_make() {
	make --no-print-directory -C "$repo" "$PB_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" \
		"$PB_VARIANT_VAR=$PB_VARIANT" STRICT_TOOLS=1 AWK=awk "$@"
}

# Same fake toolchain, but aimed at whichever target owns the variant matrix.
run_matrix_make() {
	make --no-print-directory -C "$repo" "$PB_MATRIX_TARGET" \
		CC=true HOSTCC=true "$PB_CC_VAR=$tools/xc8" "$PB_BUILD_DIR_VAR=$PB_BUILD_DIR" \
		"$PB_FW_BASE_VAR=$PB_FW_BASE" "$PB_TAG_VAR=$PB_TAG" \
		"$PB_FLASH_VAR=$PB_FLASH_WORDS" STRICT_TOOLS=1 AWK=awk "$@"
}

remove_matrix_images() {
	local image
	for image in $PB_MATRIX_IMAGES; do
		rm -f "$repo/$PB_BUILD_DIR/$image"
	done
}

assert_no_matrix_images() {
	local image
	for image in $PB_MATRIX_IMAGES; do
		[[ ! -e "$repo/$PB_BUILD_DIR/$image" && ! -L "$repo/$PB_BUILD_DIR/$image" ]] \
			|| { printf 'FAIL: rejected %s matrix left image %s\n' \
				"$PB_LABEL" "$image" >&2; exit 1; }
	done
}

expect_build_matrix_rejected() {
	local label=$1 matrix=$2 marker=$3 output
	remove_matrix_images
	if output=$(run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$matrix" 2>&1); then
		printf 'FAIL: %s build matrix accepted %s\n' "$PB_LABEL" "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$marker"* ]] \
		|| { printf 'FAIL: %s build matrix reported the wrong %s error: %s\n' \
			"$PB_LABEL" "$label" "$output" >&2; exit 1; }
	assert_no_matrix_images
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
	printf 'stale image\n' > "$hex"
	if (export FAKE_XC8_MODE="$mode"; run_make) >/dev/null 2>&1; then
		printf 'FAIL: XC8 mode %s was accepted\n' "$mode" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: XC8 mode %s left a stale or invalid image\n' "$mode" >&2; exit 1; }
	checks=$((checks + 1))
done

marker="$work/build.signal-delivered"
rm -f "$marker"
printf 'stale image\n' > "$hex"
if (export FAKE_XC8_MODE=signal FAKE_XC8_SIGNAL_MARKER="$marker"; \
		run_make) >/dev/null 2>&1; then
	printf 'FAIL: interrupted PIC build exited successfully\n' >&2
	exit 1
fi
[[ -f "$marker" ]] \
	|| { printf 'FAIL: PIC build signal fixture did not deliver SIGTERM\n' >&2; exit 1; }
[[ ! -e "$hex" && ! -L "$hex" ]] \
	|| { printf 'FAIL: interrupted PIC build left a partial image\n' >&2; exit 1; }
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
fi

if (export FAKE_XC8_FAIL_NAME="$PB_MATRIX_FAIL_IMAGE"; \
		run_matrix_make "$PB_MATRIX_VARIANTS_VAR=$PB_MATRIX_VARIANTS") >/dev/null 2>&1; then
	printf 'FAIL: late %s variant compiler failure was accepted\n' "$PB_LABEL" >&2
	exit 1
fi
assert_no_matrix_images
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

printf '%s build validation: %d checks, 0 failures\n' "$PB_LABEL" "$checks"
