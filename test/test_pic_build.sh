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
PB_TARGET=${PB_TARGET:-pic10f322}
PB_CC_VAR=${PB_CC_VAR:-PIC_CC}
PB_BUILD_DIR_VAR=${PB_BUILD_DIR_VAR:-PIC10F322_BUILD_DIR}
PB_BUILD_DIR=${PB_BUILD_DIR:-build_pic10f322}
PB_FW_BASE_VAR=${PB_FW_BASE_VAR:-FW_BASE}
PB_FW_BASE=${PB_FW_BASE:-bypass}
PB_TAG_VAR=${PB_TAG_VAR:-PIC10F322_TAG}
PB_TAG=${PB_TAG:-pic10f322}
PB_FLASH_VAR=${PB_FLASH_VAR:-PIC10F322_FLASH_WORDS}
PB_FLASH_WORDS=${PB_FLASH_WORDS:-512}
PB_VARIANT_VAR=${PB_VARIANT_VAR:-VARIANTS}
PB_VARIANT=${PB_VARIANT:-cd4053_simple}
# The all-variant build target, and the images it must produce. `pic10f322` builds the
# whole VARIANTS matrix in one invocation; the PIC10F320 lane splits that into
# per-variant `pic10f320` plus the `pic10f320-variants` aggregate, so the matrix checks
# below point at whichever target owns the matrix for this chip.
PB_MATRIX_TARGET=${PB_MATRIX_TARGET:-pic10f322}
PB_MATRIX_VARIANTS_VAR=${PB_MATRIX_VARIANTS_VAR:-VARIANTS}
PB_MATRIX_VARIANTS=${PB_MATRIX_VARIANTS:-cd4053_simple cd4053_with_mute tq2_l2_5v_relay}
PB_MATRIX_IMAGES=${PB_MATRIX_IMAGES:-bypass-pic10f322-cd4053_simple.hex bypass-pic10f322-cd4053_with_mute.hex bypass-pic10f322-tq2_l2_5v_relay.hex}
PB_MATRIX_FAIL_IMAGE=${PB_MATRIX_FAIL_IMAGE:-bypass-pic10f322-tq2_l2_5v_relay.hex}
PB_MATRIX_REQUIRE_COMPLETE=${PB_MATRIX_REQUIRE_COMPLETE:-1}
PB_MATRIX_UNSUPPORTED=${PB_MATRIX_UNSUPPORTED:-unknown}
PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-}
PB_SELECTOR_ROUTING=${PB_SELECTOR_ROUTING:-0}
PB_SIZE_TARGET=${PB_SIZE_TARGET:-}
PB_STACK_TARGET=${PB_STACK_TARGET:-pic10f322-test-stack-bound}
PB_STACK_DEVICE_VAR=${PB_STACK_DEVICE_VAR:-PIC10F322_DEVICE_INI}
PB_RETURN_STACK_REQUIRED=${PB_RETURN_STACK_REQUIRED:-0}
PB_REBUILD_REQUIRED=${PB_REBUILD_REQUIRED:-0}
product_override_args=()
matrix_supported_var=
case "$PB_TARGET" in
	pic10f322)
		[ "$PB_LABEL" = PIC ] \
			|| { printf 'FAIL: canonical pic10f322 build validation requires PB_LABEL=PIC\n' >&2; exit 1; }
		PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-$PB_MATRIX_VARIANTS}
		product_override_args=(PIC10F322_HEXES= PIC10F322_ASSEMBLIES= PIC10F322_SYMBOLS= PIC10F322_BUILD_PRODUCTS=)
		matrix_supported_var=CLASSIC_VARIANTS_SUPPORTED
		expected_checks=36
		;;
	pic10f320)
		[ "$PB_LABEL" = PIC10F320 ] \
			|| { printf 'FAIL: canonical pic10f320 build validation requires PB_LABEL=PIC10F320\n' >&2; exit 1; }
		[ "$PB_REBUILD_REQUIRED" = 1 ] \
			|| { printf 'FAIL: canonical pic10f320 build validation requires PB_REBUILD_REQUIRED=1\n' >&2; exit 1; }
		PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-$PB_VARIANT}
		product_override_args=(PIC10F320_HEX= PIC10F320_ASM= PIC10F320_SYM= PIC10F320_BUILD_PRODUCTS=)
		# This lane's supported set is PIC10F320_VARIANTS_ALL, which is a plain
		# literal rather than the CLASSIC_VARIANTS_* machinery, so the
		# self-whitelisting Make-function attack below does not apply to it.
		matrix_supported_var=
		expected_checks=75
		;;
	pic12f675)
		[ "$PB_LABEL" = PIC12F675 ] \
			|| { printf 'FAIL: canonical pic12f675 build validation requires PB_LABEL=PIC12F675\n' >&2; exit 1; }
		PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-$PB_MATRIX_VARIANTS}
		product_override_args=(PIC12F675_HEXES= PIC12F675_ASSEMBLIES= PIC12F675_SYMBOLS= PIC12F675_BUILD_PRODUCTS=)
		# Same CLASSIC_VARIANTS_* validation preamble as the PIC10F322 target,
		# so it is exposed to the same injection vector and must run the same
		# check. Its additional checks pin simulator-image path separation and
		# complete-matrix production/consumption.
		matrix_supported_var=CLASSIC_VARIANTS_SUPPORTED
		expected_checks=49
		;;
	*) PB_BUILD_VARIANTS=${PB_BUILD_VARIANTS:-$PB_VARIANT}; matrix_supported_var=; expected_checks= ;;
esac
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
	MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
mkdir -p "$repo/src" "$repo/scripts" "$repo/test/pic10f320/equiv" \
	"$repo/test/pic10f320/actuation" "$repo/test/pic10f320/fault" \
	"$repo/build_pic10f322" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$repo/scripts/validate-ihex.sh"
cp "$ROOT/test/check_stack_depth_pic.sh" "$repo/test/check_stack_depth_pic.sh"
cp "$ROOT/test/pic10f320/return_stack_oracle.py" \
	"$repo/test/pic10f320/return_stack_oracle.py"
cp "$ROOT/test/pic10f320/check_expected_images.py" \
	"$repo/test/pic10f320/check_expected_images.py"
: > "$xc8_log"
: > "$host_cc_log"
: > "$host_run_log"
export FAKE_XC8_LOG="$xc8_log"
# The over-budget fixture must be over THIS lane's budget, not a fixed 513: a
# 513-word image is comfortably inside a 1024-word part, so a hard-coded value
# silently stopped testing the budget gate the moment a bigger part arrived.
# One word past is also a sharper test than "far over" -- it pins the boundary.
export FAKE_XC8_OVER_BUDGET_WORDS=$((PB_FLASH_WORDS + 1))

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
	over-budget) printf 'Program space used (%s)\n' "${FAKE_XC8_OVER_BUDGET_WORDS:-513}" ;;
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
	hash-mismatch) write_hash_mismatch_hex > "$out" ;;
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
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_pic10f322.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h src/bypass_output_cd4053_simple.c
	src/bypass_output_cd4053_with_mute.c src/bypass_output_tq2_l2_5v_relay.c
	src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h
	src/bypass_output_tq2_l2_5v_relay.h
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
	cp "$ROOT/test/pic/inject_calibration_word.py" \
		"$repo/test/pic/inject_calibration_word.py"

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
			':02400E009E38DA' \
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
	for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
		[ "$(grep -cF "CALIBRATION PASS [$variant]:" <<<"$cal_output")" -eq 1 ] \
			|| { printf 'FAIL: PIC12F675 calibration contract did not check %s exactly once: %s\n' \
				"$variant" "$cal_output" >&2; exit 1; }
	done
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
	# failure. Both paths remove stale expected derived images.
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
fi

[ -z "$expected_checks" ] || [ "$checks" -eq "$expected_checks" ] \
	|| { printf 'FAIL: canonical %s build validation ran %d checks, expected %d\n' \
		"$PB_TARGET" "$checks" "$expected_checks" >&2; exit 1; }
printf '%s build validation: %d checks, 0 failures\n' "$PB_LABEL" "$checks"
