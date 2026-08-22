#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
		# complete-matrix production/consumption and the hardware-programming
		# calibration guard.
		matrix_supported_var=CLASSIC_VARIANTS_SUPPORTED
		expected_checks=126
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
	PIC12F675_PART PIC12F675_PROG PIC12F675_PROG_KIND PIC12F675_PROG_TOOL \
	PIC12F675_READ_PROG PIC12F675_TRIM_EVIDENCE PIC12F675_BENCH_RESULT \
	PIC12F675_PROG_HEX PIC12F675_PROG_CMD \
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
	case "${out:-}" in
		*-cd4053_with_mute.hex) program_record=:040000000100FF23D9 ;;
		*-tq2_l2_5v_relay.hex) program_record=:040000000200FF23D8 ;;
		*) program_record=:040000000000FF23DA ;;
	esac
	case "${FAKE_XC8_PIC12F675_MODE:-default}" in
		shipping)
			printf '%s\n' "$program_record" ':02400E00CC31B3' ':00000001FF'
			;;
		byte-different)
			case "${out:-}" in
				*-cd4053_simple.hex) program_record=:040000000300FF23D7 ;;
			esac
			printf '%s\n' "$program_record" ':02400E00CC31B3' ':00000001FF'
			;;
		bad-config)
			printf '%s\n' "$program_record" ':02400E00CD31B2' ':00000001FF'
			;;
		bad-fosc)
			printf '%s\n' "$program_record" ':02400E00CD31B2' ':00000001FF'
			;;
		bad-wdte)
			printf '%s\n' "$program_record" ':02400E00C431BB' ':00000001FF'
			;;
		bad-mclre)
			printf '%s\n' "$program_record" ':02400E00EC3193' ':00000001FF'
			;;
		bad-boren)
			printf '%s\n' "$program_record" ':02400E008C31F3' ':00000001FF'
			;;
		bad-bg)
			printf '%s\n' "$program_record" ':02400E00CC21C3' ':00000001FF'
			;;
		bad-full-word)
			printf '%s\n' "$program_record" ':02400E00CC33B1' ':00000001FF'
			;;
		overlap)
			printf '%s\n' "$program_record" ':02000200FF23DA' \
				':02400E00CC31B3' ':00000001FF'
			;;
		derived)
			printf '%s\n' "$program_record" ':02400E00CC31B3' \
				':0207FE00803445' ':00000001FF'
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
	cp "$ROOT/test/.gitignore" "$repo/test/.gitignore"
	cp "$ROOT/test/pic/test_config_pic12f675.c" \
		"$repo/test/pic/test_config_pic12f675.c"
	cp "$ROOT/test/pic/test_config_pic_core.h" \
		"$repo/test/pic/test_config_pic_core.h"
	cp "$ROOT/test/pic/pic12f675_config.h" \
		"$repo/test/pic/pic12f675_config.h"
	cp "$ROOT/test/pic/inject_calibration_word.py" \
		"$repo/test/pic/inject_calibration_word.py"
	cp "$ROOT/test/pic/pic12f675_trim_evidence.py" \
		"$repo/test/pic/pic12f675_trim_evidence.py"
	cp "$ROOT/test/pic/pic12f675_matrix_evidence.py" \
		"$repo/test/pic/pic12f675_matrix_evidence.py"
	cp "$ROOT/scripts/verify-release-program-image.sh" \
		"$repo/scripts/verify-release-program-image.sh"
	cp "$ROOT/scripts/verify-release-images.sh" \
		"$repo/scripts/verify-release-images.sh"
	cp "$ROOT/scripts/release-signing-policy.sh" \
		"$repo/scripts/release-signing-policy.sh"

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

	write_program_fixture() {
		local path=$1 variant=$2 record
		case "$variant" in
			cd4053_with_mute) record=:040000000100FF23D9 ;;
			tq2_l2_5v_relay) record=:040000000200FF23D8 ;;
			*) record=:040000000000FF23DA ;;
		esac
		printf '%s\n' "$record" ':02400E00CC31B3' ':00000001FF' > "$path"
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

	program_log="$work/pic12f675-program.log"
	hardware_log="$work/pic12f675-hardware.log"
	program_capture="$work/pic12f675-program.hex"
	program_late_marker="$work/pic12f675-late-replacement"
	program_transaction="$work/pic12f675-current-transaction"
	program_device_state="$work/pic12f675-device-programmed"
	program_evidence="$work/pic12f675-trim-baseline.json"
	pic12_temp_root="$work/PIC12F675 private temporary root"
	pic12_temp_cleanup_failure="$work/pic12f675-temp-cleanup-failed"
	mkdir -p "$pic12_temp_root"
	chmod 700 "$pic12_temp_root"
	rm -f "$pic12_temp_cleanup_failure"
	programmer="$tools/pic12f675-programmer"
	cat > "$programmer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
image=
read_hex=
identity=0
printf '[' >> "${PIC12F675_HARDWARE_LOG:?}"
printf ' %q' "$@" >> "$PIC12F675_HARDWARE_LOG"
printf ' ]\n' >> "$PIC12F675_HARDWARE_LOG"
if [[ "${1:-}" == '-?V' ]]; then
	if [[ "${PIC12F675_PROGRAMMER_MODE:-read}" == recovery-version-mismatch ]]; then
		printf 'pk2cmd fixture version 1.22\n'
		exit 0
	fi
	printf 'pk2cmd fixture version 1.21\n'
	exit 0
fi
if [[ "${1:-}" == '-?' ]]; then
	printf 'ipecmd fixture version 6.20\n'
	exit 0
fi
for arg in "$@"; do
	case "$arg" in
		-GF*) read_hex=${arg#-GF} ;;
		-F*) image=${arg#-F} ;;
		-I) identity=1 ;;
	esac
done
if [[ "$identity" -eq 1 && -z "$read_hex" ]]; then
	printf 'Target PIC12F675\nDevice ID = 0x0FC0\nDevice Revision = 0x0001\n'
	exit 0
fi
if [[ -n "$read_hex" ]]; then
	if [[ -e "${PIC12F675_PROGRAM_TRANSACTION:?}" \
			&& "${PIC12F675_PROGRAMMER_MODE:-read}" == post-read-fail ]]; then
		printf 'forced post-program read failure\n' >&2
		exit 92
	fi
	osccal=:0207FE00A53420
	config=:02400E00FF11A0
	device_id=0x0FC0
	device_revision=0x0001
	if [[ -e "${PIC12F675_DEVICE_STATE:?}" ]]; then
		config=:02400E00CC11D3
	fi
	if [[ ! -e "$PIC12F675_PROGRAM_TRANSACTION" \
			&& "${PIC12F675_PROGRAMMER_MODE:-read}" == prewrite-change ]]; then
		osccal=:0207FE00A6341F
	fi
	if [[ -e "$PIC12F675_PROGRAM_TRANSACTION" ]]; then
		case "${PIC12F675_PROGRAMMER_MODE:-read}" in
			change-osccal) osccal=:0207FE00A6341F ;;
			change-bg) config=:02400E00CC21C3 ;;
			wrong-config) config=:02400E00CD11D2 ;;
			change-identity) device_id=0x0FC1 ;;
		esac
	fi
	program_record=
	if [[ -e "${PIC12F675_DEVICE_STATE:?}" && -f "${PIC12F675_PROGRAM_CAPTURE:?}" ]]; then
		IFS= read -r program_record < "$PIC12F675_PROGRAM_CAPTURE"
	fi
	if [[ -e "$PIC12F675_PROGRAM_TRANSACTION" \
			&& "${PIC12F675_PROGRAMMER_MODE:-read}" == wrong-program-byte ]]; then
		program_record=:040000000300FF23D7
	fi
	# Real programmer exports may open with an extended linear address record.
	# A zero base is a no-op, so every lane runs against one; a non-zero base
	# relocates, and must be refused rather than silently moving the words the
	# trim comparisons are identified by. validate-ihex.sh accepts both -- it
	# checks the record's shape, not its payload -- so only the evidence parser
	# can tell them apart.
	base=:020000040000FA
	if [[ "${PIC12F675_PROGRAMMER_MODE:-read}" == relocated-read ]]; then
		base=:0200000480007A
	fi
	if [[ -n "$program_record" ]]; then
		printf '%s\n' "$base" "$program_record" "$osccal" "$config" \
			':00000001FF' > "$read_hex"
	else
		printf '%s\n' "$base" "$osccal" "$config" ':00000001FF' > "$read_hex"
	fi
	if [[ -e "$PIC12F675_PROGRAM_TRANSACTION" \
			&& "${PIC12F675_PROGRAMMER_MODE:-read}" == malformed-recovery-read ]]; then
		printf '%s\n' "$base" "$program_record" "$osccal" ':00000001FF' > "$read_hex"
	fi
	if [[ -e "$PIC12F675_PROGRAM_TRANSACTION" \
			&& "${PIC12F675_PROGRAMMER_MODE:-read}" == signal-recovery-read ]]; then
		kill -TERM "$PPID"
		sleep 1
		exit 96
	fi
	printf 'Target PIC12F675\nDevice ID = %s\nDevice Revision = %s\n' \
		"$device_id" "$device_revision"
	exit 0
fi
[[ -n "$image" && -f "$image" && ! -L "$image" && -s "$image" ]] \
	|| { printf 'programmer did not receive a nonempty regular -F image\n' >&2; exit 91; }
printf '%s\0' "$@" >> "${PIC12F675_PROGRAM_LOG:?}"
if [[ "${PIC12F675_PROGRAMMER_MODE:-read}" == no-op ]]; then
	: > "$PIC12F675_PROGRAM_TRANSACTION"
	printf 'Target PIC12F675\nDevice ID = 0x0FC0\nDevice Revision = 0x0001\nProgram complete\n'
	exit 0
fi
if [[ "${PIC12F675_PROGRAMMER_MODE:-read}" == writer-fail ]]; then
	: > "$PIC12F675_PROGRAM_TRANSACTION"
	printf 'forced writer failure\n' >&2
	exit 94
fi
if [[ "${PIC12F675_PROGRAMMER_MODE:-read}" == replace ]]; then
	if mv -- "$image" "$image.late" 2>/dev/null; then
		cp -- "${PIC12F675_PROGRAMMER_REPLACEMENT:?}" "$image"
		printf 'replaced\n' > "${PIC12F675_PROGRAMMER_MARKER:?}"
	else
		printf 'blocked\n' > "${PIC12F675_PROGRAMMER_MARKER:?}"
	fi
fi
rm -f -- "${PIC12F675_PROGRAM_CAPTURE:?}"
cp -- "$image" "$PIC12F675_PROGRAM_CAPTURE"
: > "$PIC12F675_DEVICE_STATE"
: > "$PIC12F675_PROGRAM_TRANSACTION"
if [[ "${PIC12F675_PROGRAMMER_MODE:-read}" == signal-after-write ]]; then
	printf 'program bytes consumed before forced signal\n'
	kill -TERM "$PPID"
	sleep 1
	exit 95
fi
printf 'Target PIC12F675\nDevice ID = 0x0FC0\nDevice Revision = 0x0001\nProgram complete\n'
EOF
	cat > "$tools/near-match-checker.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("PIC12F675_CALIBRATION_CHECK PASS image=%s word=0x3FF trailing-output"
      % sys.argv[-1])
EOF
	real_config_checker="$tools/test_config_pic12f675"
	cc -std=c11 -O2 -Wall -Wextra -Werror -I"$ROOT/test" \
		-DPIC_DEVICE_NAME='"PIC12F675"' \
		"$ROOT/test/pic/test_config_pic12f675.c" -o "$real_config_checker"
	config_host_cc="$tools/pic12f675-config-host-cc"
	cat > "$config_host_cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=
compile_args=()
while (($#)); do
	if [[ "$1" == -o ]]; then
		out=${2:?}
		compile_args+=("$1" "$2.real")
		shift 2
	else
		compile_args+=("$1")
		shift
	fi
done
[[ -n "$out" ]] || { printf 'fixture CONFIG compiler received no output path\n' >&2; exit 2; }
case "${PIC12F675_CONFIG_MODE:-check}" in
	check|replace) "${PIC12F675_REAL_HOSTCC:?}" "${compile_args[@]}" ;;
	no-output|near-match|wrong-image) ;;
	*) printf 'unknown fixture CONFIG mode\n' >&2; exit 93 ;;
esac
cat > "$out" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
image=${!#}
case "${PIC12F675_CONFIG_MODE:-check}" in
	check) exec "$0.real" "$@" ;;
	replace)
		"$0.real" "$@"
		mv -- "$image" "$image.checked"
		cp -- "${PIC12F675_CONFIG_REPLACEMENT:?}" "$image"
		;;
	no-output) exit 0 ;;
	near-match)
		printf 'PIC_CONFIG_CHECK PASS device=PIC12F675 image=%s word=0x31CC trailing-output\n' "$image"
		;;
	wrong-image)
		printf 'PIC_CONFIG_CHECK PASS device=PIC12F675 image=%s.wrong word=0x31CC\n' "$image"
		;;
	*) exit 93 ;;
esac
RUNNER
chmod 750 "$out"
EOF
	stale_config_marker="$work/stale-config-checker-ran"
	cat > "$repo/test/pic/test_config_pic12f675" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
image=${!#}
: > "${PIC12F675_STALE_CONFIG_MARKER:?}"
printf 'PIC_CONFIG_CHECK PASS device=PIC12F675 image=%s word=0x31CC\n' "$image"
EOF
	chmod 750 "$programmer" "$config_host_cc" \
		"$repo/test/pic/test_config_pic12f675"
	rm -f "$stale_config_marker"

	assert_pic12_temp_root_empty() (
		[[ -d "$pic12_temp_root" && ! -L "$pic12_temp_root" ]] || {
			: > "$pic12_temp_cleanup_failure"
			printf 'FAIL: PIC12F675 workflow removed or replaced its caller-owned temporary root\n' >&2
			return 1
		}
		shopt -s nullglob dotglob
		entries=("$pic12_temp_root"/*)
		((${#entries[@]} == 0)) || {
			: > "$pic12_temp_cleanup_failure"
			printf 'FAIL: PIC12F675 workflow left transient data under its private root\n' >&2
			return 1
		}
	)

	run_program_make() {
		local build_dir=$1 variant=$2
		local result_path="$work/result-${BASHPID}-${RANDOM}.json"
		local program_target=${PIC12F675_PROGRAM_TARGET:-pic12f675-program}
		local make_rc=0
		shift 2
		rm -f "$program_transaction" "$program_device_state" "$program_capture"
		TMPDIR="${PIC12F675_TEST_TMPDIR:-$pic12_temp_root}" \
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
		PIC12F675_PROGRAM_LOG="$program_log" \
		PIC12F675_HARDWARE_LOG="$hardware_log" \
		PIC12F675_PROGRAM_CAPTURE="$program_capture" \
		PIC12F675_PROGRAMMER_MARKER="$program_late_marker" \
		PIC12F675_PROGRAM_TRANSACTION="$program_transaction" \
		PIC12F675_DEVICE_STATE="$program_device_state" \
		PIC12F675_PROGRAMMER_MODE="${PIC12F675_PROGRAMMER_MODE:-read}" \
		PIC12F675_PROGRAMMER_REPLACEMENT="${PIC12F675_PROGRAMMER_REPLACEMENT:-}" \
		PIC12F675_CONFIG_MODE="${PIC12F675_CONFIG_MODE:-check}" \
		PIC12F675_CONFIG_REPLACEMENT="${PIC12F675_CONFIG_REPLACEMENT:-}" \
		PIC12F675_REAL_HOSTCC=cc \
		PIC12F675_STALE_CONFIG_MARKER="$stale_config_marker" \
		FAKE_XC8_PIC12F675_MODE="${PIC12F675_PROGRAM_IMAGE_MODE:-shipping}" \
		FAKE_XC8_MODE="${PIC12F675_PROGRAM_XC8_MODE:-pass}" \
			make --no-print-directory -C "$repo" \
				"$program_target" \
				CC=true HOSTCC="$config_host_cc" PIC12F675_BUILD_DIR="$build_dir" \
				PIC_CC="$tools/xc8" \
				FW_BASE="$PB_FW_BASE" PIC12F675_TAG="$PB_TAG" \
				PIC12F675_FLASH_WORDS="$PB_FLASH_WORDS" \
				VARIANT="$variant" PIC12F675_PROG="$programmer" \
				PIC12F675_READ_PROG="$programmer" \
				PIC12F675_TRIM_EVIDENCE="$program_evidence" \
				PIC12F675_BENCH_RESULT="$result_path" \
				PIC12F675_PART=PIC10F322 \
				PIC12F675_CAL_INJECTOR="$tools/noop-oracle.py" \
				PIC12F675_CAL_CHECKER="$tools/noop-oracle.py" \
				STRICT_TOOLS=1 "$@" || make_rc=$?
		assert_pic12_temp_root_empty || return 99
		return "$make_rc"
	}

	run_finalize_make() {
		local result_dir=$1 variant=$2
		local make_rc=0
		shift 2
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
		PIC12F675_PROGRAM_LOG="$program_log" \
		PIC12F675_HARDWARE_LOG="$hardware_log" \
		PIC12F675_PROGRAM_CAPTURE="$program_capture" \
		PIC12F675_PROGRAMMER_MARKER="$program_late_marker" \
		PIC12F675_PROGRAM_TRANSACTION="$program_transaction" \
		PIC12F675_DEVICE_STATE="$program_device_state" \
		PIC12F675_PROGRAMMER_MODE="${PIC12F675_PROGRAMMER_MODE:-read}" \
			make --no-print-directory -C "$repo" pic12f675-finalize \
				CC=true HOSTCC=true VARIANT="$variant" \
				PIC12F675_PROG="$programmer" PIC12F675_PROG_KIND=pk2cmd \
				PIC12F675_READ_PROG="$programmer" \
				PIC12F675_TRIM_EVIDENCE="$program_evidence" \
				PIC12F675_BENCH_RESULT="$result_dir" \
				PIC12F675_PART=PIC10F322 STRICT_TOOLS=1 "$@" || make_rc=$?
		return "$make_rc"
	}

	run_preflight_make() {
		local make_rc=0
		TMPDIR="${PIC12F675_TEST_TMPDIR:-$pic12_temp_root}" \
		_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
		PIC12F675_PROGRAMMER_MODE="${PIC12F675_PROGRAMMER_MODE:-read}" \
		PIC12F675_HARDWARE_LOG="$hardware_log" \
		PIC12F675_PROGRAM_LOG="$program_log" \
		PIC12F675_PROGRAM_CAPTURE="$program_capture" \
		PIC12F675_PROGRAMMER_MARKER="$program_late_marker" \
		PIC12F675_PROGRAM_TRANSACTION="$program_transaction" \
		PIC12F675_DEVICE_STATE="$program_device_state" \
			make --no-print-directory -C "$repo" pic12f675-preflight \
				PIC12F675_READ_PROG="$programmer" \
				PIC12F675_TRIM_EVIDENCE="$program_evidence" \
				PIC12F675_PART=PIC10F322 STRICT_TOOLS=1 "$@" || make_rc=$?
		assert_pic12_temp_root_empty || return 99
		return "$make_rc"
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
	for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
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
	# Restore a coherent retained fixture for the pre-existing programming and
	# simcal publication probes below; the mutation check intentionally left one
	# shipping file malformed after EOF.
	run_matrix_qualifier >/dev/null

	program_variant=cd4053_simple
	program_source="$work/program-$program_variant.hex"
	write_program_fixture "$program_source" "$program_variant"
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

	# A separate read-only target creates the baseline before any programming
	# target is allowed to build or write. The immutable part defeats the same
	# wrong-device command-line override exercised by the write target.
	: > "$hardware_log"
	: > "$program_log"
	rm -f "$program_evidence" "$program_device_state" "$program_transaction"
	preflight_output=$(run_preflight_make)
	printf -v expected_preflight_prefix '%q' \
		"-GF$pic12_temp_root/pic12f675-preflight."
	[[ "$preflight_output" == *"pk2cmd fixture version 1.21"* \
		&& "$preflight_output" == *"PIC12F675_TRIM_BASELINE PASS evidence=$program_evidence"* \
		&& -f "$program_evidence" && ! -L "$program_evidence" \
		&& ! -s "$program_log" \
		&& "$(<"$hardware_log")" == *"[ -\?V ]"* \
		&& "$(<"$hardware_log")" == *"[ -PPIC12F675 -I -GF"*" -R ]"* \
		&& "$(<"$hardware_log")" == *"$expected_preflight_prefix"*"/device-read.hex"* ]] \
		|| { printf 'FAIL: PIC12F675 read-only preflight did not retain the expected baseline: %s\n' \
			"$preflight_output" >&2; exit 1; }
	python3 - "$program_evidence" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
assert record["part"] == "PIC12F675"
assert record["device_id"] == "0x0FC0"
assert record["device_revision"] == "0x0001"
assert record["osccal_word"] == "0x34A5"
assert record["config_word"] == "0x11FF"
assert record["bg_bits"] == "0x1000"
PY
	checks=$((checks + 1))

	# Shared temporary roots are rejected before a read or write, even when the
	# caller explicitly exports one. Normal scenarios in this lane all use the
	# whitespace-bearing private root above and the wrappers assert it is empty
	# after every success, failure, and signal interruption.
	shared_root_evidence="$work/shared-root-evidence.json"
	: > "$hardware_log"
	if shared_root_output=$(PIC12F675_TEST_TMPDIR=/tmp run_preflight_make \
			"PIC12F675_TRIM_EVIDENCE=$shared_root_evidence" 2>&1); then
		printf 'FAIL: PIC12F675 preflight accepted shared /tmp storage\n' >&2
		exit 1
	fi
	[[ "$shared_root_output" == *"refusing shared temporary root /tmp"* \
		&& ! -s "$hardware_log" && ! -e "$shared_root_evidence" ]] \
		|| { printf 'FAIL: shared temporary root reached preflight hardware or failed for the wrong reason: %s\n' \
			"$shared_root_output" >&2; exit 1; }
	if shared_root_output=$(PIC12F675_TEST_TMPDIR=//tmp run_preflight_make \
			"PIC12F675_TRIM_EVIDENCE=$shared_root_evidence" 2>&1); then
		printf 'FAIL: PIC12F675 preflight accepted aliased shared //tmp storage\n' >&2
		exit 1
	fi
	[[ "$shared_root_output" == *"refusing shared temporary root /tmp"* \
		&& ! -s "$hardware_log" && ! -e "$shared_root_evidence" ]] \
		|| { printf 'FAIL: aliased shared temporary root failed open or for the wrong reason: %s\n' \
			"$shared_root_output" >&2; exit 1; }
	insecure_temp_root="$work/insecure temporary root"
	mkdir -p "$insecure_temp_root"
	chmod 755 "$insecure_temp_root"
	if shared_root_output=$(PIC12F675_TEST_TMPDIR="$insecure_temp_root" run_preflight_make \
			"PIC12F675_TRIM_EVIDENCE=$shared_root_evidence" 2>&1); then
		printf 'FAIL: PIC12F675 preflight accepted a group/other-accessible temporary root\n' >&2
		exit 1
	fi
	[[ "$shared_root_output" == *"must be owned by the current user with no group/other access"* \
		&& ! -s "$hardware_log" && ! -e "$shared_root_evidence" ]] \
		|| { printf 'FAIL: accessible temporary root failed open or for the wrong reason: %s\n' \
			"$shared_root_output" >&2; exit 1; }
	unsafe_temp_root="$work/unsafe\$temporary-root"
	mkdir -p "$unsafe_temp_root"
	chmod 700 "$unsafe_temp_root"
	if shared_root_output=$(PIC12F675_TEST_TMPDIR="$unsafe_temp_root" run_preflight_make \
			"PIC12F675_TRIM_EVIDENCE=$shared_root_evidence" 2>&1); then
		printf 'FAIL: PIC12F675 preflight accepted Make/shell metacharacters in its temporary root\n' >&2
		exit 1
	fi
	[[ "$shared_root_output" == *"contains unsupported path characters"* \
		&& ! -s "$hardware_log" && ! -e "$shared_root_evidence" ]] \
		|| { printf 'FAIL: metacharacter temporary root failed open or for the wrong reason: %s\n' \
			"$shared_root_output" >&2; exit 1; }
	unsafe_ancestor="$work/group-writable-ancestor"
	ancestor_temp_root="$unsafe_ancestor/private child"
	mkdir -p "$ancestor_temp_root"
	chmod 777 "$unsafe_ancestor"
	chmod 700 "$ancestor_temp_root"
	if shared_root_output=$(PIC12F675_TEST_TMPDIR="$ancestor_temp_root" run_preflight_make \
			"PIC12F675_TRIM_EVIDENCE=$shared_root_evidence" 2>&1); then
		printf 'FAIL: PIC12F675 preflight accepted a group/other-writable temporary-root ancestor\n' >&2
		exit 1
	fi
	[[ "$shared_root_output" == *"has a group/other-writable ancestor"* \
		&& ! -s "$hardware_log" && ! -e "$shared_root_evidence" ]] \
		|| { printf 'FAIL: writable temporary-root ancestor failed open or for the wrong reason: %s\n' \
			"$shared_root_output" >&2; exit 1; }
	shared_root_result="$work/shared-root-result"
	for rejected_root in \
		"/tmp|refusing shared temporary root /tmp" \
		"//tmp|refusing shared temporary root /tmp" \
		"$insecure_temp_root|must be owned by the current user with no group/other access" \
		"$unsafe_temp_root|contains unsupported path characters" \
		"$ancestor_temp_root|has a group/other-writable ancestor"; do
		temp_root=${rejected_root%%|*}
		reason=${rejected_root#*|}
		rm -rf "$shared_root_result"
		if shared_root_output=$(PIC12F675_TEST_TMPDIR="$temp_root" run_program_make \
				"$PB_BUILD_DIR" "$program_variant" \
				"PIC12F675_BENCH_RESULT=$shared_root_result" 2>&1); then
			printf 'FAIL: PIC12F675 programming accepted unsafe temporary root %s\n' "$temp_root" >&2
			exit 1
		fi
		[[ "$shared_root_output" == *"$reason"* \
			&& ! -s "$hardware_log" && ! -e "$shared_root_result" ]] \
			|| { printf 'FAIL: unsafe temporary root reached programming hardware or failed for the wrong reason: %s\n' \
				"$shared_root_output" >&2; exit 1; }
	done
	checks=$((checks + 1))

	# A read whose export RELOCATES addresses must be refused, not
	# reinterpreted: OSCCAL and CONFIG are identified by address alone, so a
	# non-zero base would move them somewhere the comparison never looks.
	# validate-ihex.sh passes this file -- it checks the record's shape, not
	# its payload -- so the evidence parser is the only thing standing here.
	: > "$hardware_log"
	rm -f "$program_evidence"
	if relocated_output=$(PIC12F675_PROGRAMMER_MODE=relocated-read \
			run_preflight_make 2>&1); then
		printf 'FAIL: PIC12F675 preflight accepted a relocated device read: %s\n' \
			"$relocated_output" >&2
		exit 1
	fi
	[[ "$relocated_output" == *"address relocation is not supported"* \
		&& ! -e "$program_evidence" ]] \
		|| { printf 'FAIL: relocated device read failed for the wrong reason: %s\n' \
			"$relocated_output" >&2; exit 1; }
	checks=$((checks + 1))

	# Re-establish the baseline the scenarios below consume.
	: > "$hardware_log"
	preflight_output=$(run_preflight_make)
	[[ "$preflight_output" == *"PIC12F675_TRIM_BASELINE PASS evidence=$program_evidence"* \
		&& -f "$program_evidence" ]] \
		|| { printf 'FAIL: PIC12F675 baseline could not be re-established: %s\n' \
			"$preflight_output" >&2; exit 1; }

	# A fresh programming invocation with no baseline fails before any hardware
	# command, as does one that has nowhere exclusive to retain the result.
	: > "$hardware_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
			PIC12F675_TRIM_EVIDENCE= 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a missing trim baseline\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"PIC12F675_TRIM_EVIDENCE is required"* \
		&& ! -s "$hardware_log" ]] \
		|| { printf 'FAIL: missing trim baseline reached hardware or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$hardware_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
			PIC12F675_BENCH_RESULT= 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a missing bench-result path\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"PIC12F675_BENCH_RESULT is required"* \
		&& ! -s "$hardware_log" ]] \
		|| { printf 'FAIL: missing bench-result path reached hardware or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# The durable result directory must be reservable before the write. A missing
	# parent may consume read-only preflight operations, but never programming.
	unreservable_result="$work/missing-result-parent/result"
	: > "$program_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_BENCH_RESULT=$unreservable_result" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted an unreservable result directory\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"bench-result parent directory does not exist"* \
		&& ! -s "$program_log" && ! -e "$program_transaction" ]] \
		|| { printf 'FAIL: unreservable result path reached programming or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# Exit status alone cannot prove a write happened. A no-op writer that reports
	# success is rejected because the post-read omits the requested image bytes.
	no_op_result="$work/no-op-result"
	rm -rf "$no_op_result"
	: > "$program_log"
	rm -f "$program_capture" "$program_device_state"
	if program_output=$(PIC12F675_PROGRAMMER_MODE=no-op \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_BENCH_RESULT=$no_op_result" 2>&1); then
		printf 'FAIL: PIC12F675 programming trusted a zero-exit no-op writer\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"post-program read omits image byte address"* \
		&& "$program_output" == *"PIC12F675_TRIM_RESULT FAIL evidence=$no_op_result/result.json"* \
		&& -f "$no_op_result/reservation.json" && -f "$no_op_result/result.json" ]] \
		|| { printf 'FAIL: no-op writer was not rejected by image readback: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# pk2cmd receives one exact, private -F snapshot of a matrix rebuilt by this
	# target. Attempts to change the chip, compiler flags, source set and programmer
	# part are ignored by their fixed PIC12F675 definitions.
	declare -A program_build_counts=()
	for image in $PB_MATRIX_IMAGES; do
		program_build_counts[$image]=$(logged_command_count "$xc8_log" "$image")
	done
	: > "$program_log"
	: > "$hardware_log"
	rm -f "$program_capture"
	program_result="$work/pic12f675-program-result"
	rm -rf "$program_result"
	program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
		PIC12F675_CHIP=12F683 \
		'PIC12F675_CFLAGS=-mcpu=12F683 -DWRONG_PROGRAM_TARGET' \
		PIC12F675_CORE_SRC=/dev/null \
		FW_BASE=../../escaped PIC12F675_TAG=wrong-part \
		"PIC12F675_BENCH_RESULT=$program_result")
	for image in $PB_MATRIX_IMAGES; do
		[[ "$(logged_command_count "$xc8_log" "$image")" \
			-eq $((program_build_counts[$image] + 1)) ]] \
			|| { printf 'FAIL: PIC12F675 programming did not freshly rebuild %s exactly once\n' \
				"$image" >&2; exit 1; }
		latest=$(latest_logged_command "$xc8_log" "$image")
		case "$image" in
			*-cd4053_with_mute.hex) expected_macro=-DCD4053_WITH_MUTE; expected_driver=bypass_output_cd4053_with_mute.c ;;
			*-tq2_l2_5v_relay.hex) expected_macro=-DTQ2_L2_5V_RELAY; expected_driver=bypass_output_tq2_l2_5v_relay.c ;;
			*) expected_macro=-DCD4053_SIMPLE; expected_driver=bypass_output_cd4053_simple.c ;;
		esac
		command_has_arg "$latest" '-mcpu=12F675' \
			&& command_has_arg "$latest" '-DBYPASS_MCU_PIC12F675' \
			&& command_has_arg "$latest" "$expected_macro" \
			&& [[ "$latest" == *"/$expected_driver"* ]] \
			&& [[ "$latest" == *"$repo/src/bypass_mcu_pic12f675.c"* \
				&& "$latest" == *"$repo/src/bypass_pure.c"* ]] \
			&& ! command_has_arg "$latest" '-mcpu=12F683' \
			&& ! command_has_arg "$latest" '-DWRONG_PROGRAM_TARGET' \
			&& ! command_has_arg "$latest" /dev/null \
			|| { printf 'FAIL: fresh programming build accepted wrong-part compiler identity for %s\n' \
				"$image" >&2; exit 1; }
	done
	mapfile -d '' -t program_args < "$program_log"
	[[ "${#program_args[@]}" -eq 5 \
		&& "${program_args[0]}" == -PPIC12F675 \
		&& "${program_args[1]}" == -F* \
		&& "${program_args[2]}" == -M \
		&& "${program_args[3]}" == -Y \
		&& "${program_args[4]}" == -R ]] \
		|| { printf 'FAIL: pk2cmd received unexpected PIC12F675 argv\n' >&2; exit 1; }
	program_snapshot=${program_args[1]#-F}
	expected_program_check="PIC12F675_CALIBRATION_CHECK PASS image=$program_snapshot word=0x3FF"
	expected_config_check="PIC_CONFIG_CHECK PASS device=PIC12F675 image=$program_snapshot word=0x31CC"
	[[ "$program_output" == *"$expected_program_check"* \
		&& "$program_output" == *"$expected_config_check"* \
		&& "$program_output" == *"development/bench programming is not bound to signed release bytes"* \
		&& "$program_output" == *"PIC12F675_TRIM_PREWRITE PASS evidence=$program_evidence"* \
		&& "$program_output" == *"PIC12F675_TRIM_RESULT PASS evidence=$program_result/result.json"* \
		&& "$program_output" == *"selected variant $program_variant from the fresh build matrix"* \
		&& "$program_snapshot" == "$pic12_temp_root"/pic12f675-program.*/"image snapshot.hex" \
		&& ! -e "$program_snapshot" \
		&& -f "$program_capture" && ! -e "$stale_config_marker" \
		&& -f "$program_result/reservation.json" \
		&& -f "$program_result/image.hex" \
		&& -f "$program_result/result.json" ]] \
		|| { printf 'FAIL: pk2cmd programming did not bind the selected image to its private checked snapshot: %s\n' \
			"$program_output" >&2; exit 1; }
	cmp -s "$program_source" "$program_capture" \
		|| { printf 'FAIL: pk2cmd did not consume the selected shipping-image bytes\n' >&2; exit 1; }
	python3 - "$program_result/result.json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
assert record["status"] == "PASS"
assert record["baseline_osccal_word"] == record["post_osccal_word"] == "0x34A5"
assert record["baseline_bg_bits"] == record["post_bg_bits"] == "0x1000"
assert record["baseline_config_word"] == "0x11FF"
assert record["post_config_word"] == "0x11CC"
assert record["writer_kind"] == "pk2cmd"
assert record["release_tag"] is None
assert record["release_source_commit"] is None
assert record["program_exit"] == record["post_read_exit"] == 0
assert record["programmed_image_bytes_verified"] > 2
PY
	checks=$((checks + 1))

	# A writer failure after the evidence directory was reserved leaves its raw
	# transcript and a final FAIL record instead of deleting the transaction.
	writer_failure_result="$work/writer-failure-result"
	rm -rf "$writer_failure_result"
	if program_output=$(PIC12F675_PROGRAMMER_MODE=writer-fail \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_BENCH_RESULT=$writer_failure_result" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a failed writer\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"programmer exited 94"* \
		&& -f "$writer_failure_result/reservation.json" \
		&& -f "$writer_failure_result/program.log" \
		&& -f "$writer_failure_result/result.json" ]] \
		|| { printf 'FAIL: failed writer did not retain its transaction: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# Once reservation succeeds, an interruption during the writer leaves the
	# intended image/pre-write record and the writer's durable log in place.
	signal_result="$work/writer-signal-result"
	rm -rf "$signal_result"
	if program_output=$(PIC12F675_PROGRAMMER_MODE=signal-after-write \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_BENCH_RESULT=$signal_result" 2>&1); then
		printf 'FAIL: interrupted PIC12F675 writer returned success\n' >&2
		exit 1
	fi
	[[ -f "$signal_result/reservation.json" && -f "$signal_result/image.hex" \
		&& -f "$signal_result/program.log" \
		&& "$(<"$signal_result/program.log")" == *"program bytes consumed before forced signal"* \
		&& ! -e "$signal_result/result.json" ]] \
		|| { printf 'FAIL: interrupted writer lost its reserved transaction: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# Recovery rejects every caller-selected identity mismatch before even the
	# read-only hardware operations. The image and part probes mutate copies of
	# the reservation itself; its strict parser must reject both.
	different_baseline="$work/different-pic12f675-baseline.json"
	cp "$program_evidence" "$different_baseline"
	chmod 600 "$different_baseline"
	python3 - "$different_baseline" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
record["created_utc"] = "2000-01-01T00:00:00Z"
with open(sys.argv[1], "w", encoding="ascii") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
	chmod 400 "$different_baseline"
	different_reader="$tools/different-pic12f675-reader"
	different_writer="$tools/different-pic12f675-writer"
	cp "$programmer" "$different_reader"
	cp "$programmer" "$different_writer"
	chmod 750 "$different_reader" "$different_writer"
	for mismatch in baseline variant reader writer; do
		: > "$hardware_log"
		case "$mismatch" in
			baseline)
			reason="reservation baseline digest differs from selected baseline"
			finalize_args=("PIC12F675_TRIM_EVIDENCE=$different_baseline")
			finalize_variant=$program_variant
			;;
			variant)
			reason="reservation variant differs from selected variant"
			finalize_args=()
			finalize_variant=cd4053_with_mute
			;;
			reader)
			reason="reservation reader identity differs from selected reader"
			finalize_args=("PIC12F675_READ_PROG=$different_reader")
			finalize_variant=$program_variant
			;;
			writer)
			reason="reservation writer identity differs from selected writer"
			finalize_args=("PIC12F675_PROG=$different_writer")
			finalize_variant=$program_variant
			;;
		esac
		if recovery_output=$(run_finalize_make "$signal_result" "$finalize_variant" \
				"${finalize_args[@]}" 2>&1); then
			printf 'FAIL: recovery accepted a different %s\n' "$mismatch" >&2
			exit 1
		fi
		[[ "$recovery_output" == *"$reason"* && ! -s "$hardware_log" \
			&& ! -e "$signal_result/result.json" ]] \
			|| { printf 'FAIL: different recovery %s reached hardware or failed for the wrong reason: %s\n' \
				"$mismatch" "$recovery_output" >&2; exit 1; }
		checks=$((checks + 1))
	done

	for mutation in part image; do
		mutated_result="$work/recovery-$mutation-mismatch"
		cp -a "$signal_result" "$mutated_result"
		chmod 700 "$mutated_result"
		chmod 600 "$mutated_result/reservation.json"
		python3 - "$mutated_result/reservation.json" "$mutation" <<'PY'
import base64
import hashlib
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
if sys.argv[2] == "part":
    record["part"] = "PIC12F683"
else:
    image = b":00000001FF\n"
    record["image_base64"] = base64.b64encode(image).decode("ascii")
    record["image_sha256"] = hashlib.sha256(image).hexdigest()
with open(sys.argv[1], "w", encoding="ascii") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
		chmod 400 "$mutated_result/reservation.json"
		: > "$hardware_log"
		if recovery_output=$(run_finalize_make "$mutated_result" "$program_variant" 2>&1); then
			printf 'FAIL: recovery accepted a different reserved %s\n' "$mutation" >&2
			exit 1
		fi
		case "$mutation" in
			part) reason="program reservation has the wrong schema, type, status, or part" ;;
			image) reason="retained recovery image differs from reservation" ;;
		esac
		[[ "$recovery_output" == *"$reason"* && ! -s "$hardware_log" \
			&& ! -e "$mutated_result/result.json" ]] \
			|| { printf 'FAIL: different reserved %s reached hardware or failed for the wrong reason: %s\n' \
				"$mutation" "$recovery_output" >&2; exit 1; }
		checks=$((checks + 1))
	done

	# The reader version must still match the reservation before the device read.
	# A handled interruption during that read removes only its private attempt and
	# leaves the transaction retryable; an abandoned attempt from SIGKILL/power loss
	# is safely removed by the next invocation.
	: > "$hardware_log"
	if recovery_output=$(PIC12F675_PROGRAMMER_MODE=recovery-version-mismatch \
			run_finalize_make "$signal_result" "$program_variant" 2>&1); then
		printf 'FAIL: recovery accepted a changed reader version\n' >&2
		exit 1
	fi
	mapfile -t recovery_hardware < "$hardware_log"
	[[ "$recovery_output" == *"recovery reader version differs from reservation"* \
		&& "${#recovery_hardware[@]}" -eq 1 \
		&& "${recovery_hardware[0]}" == *"[ -\\?V ]"* \
		&& ! -e "$signal_result/result.json" ]] \
		|| { printf 'FAIL: changed recovery reader version reached the device: %s\n' \
			"$recovery_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$hardware_log"
	if recovery_output=$(PIC12F675_PROGRAMMER_MODE=signal-recovery-read \
			run_finalize_make "$signal_result" "$program_variant" 2>&1); then
		printf 'FAIL: interrupted finalization returned success\n' >&2
		exit 1
	fi
	if compgen -G "$signal_result/.recovery-*" >/dev/null; then
		printf 'FAIL: handled finalization interruption left a private attempt\n' >&2
		exit 1
	fi
	[[ ! -e "$signal_result/result.json" ]] \
		|| { printf 'FAIL: interrupted finalization published a result\n' >&2; exit 1; }
	checks=$((checks + 1))
	mkdir "$signal_result/.recovery-stale"
	printf 'abandoned recovery attempt\n' > "$signal_result/.recovery-stale/read.log"

	# Matching live state resolves the original PENDING transaction using exactly
	# one version query and one read. The writer argv log must remain byte-identical.
	pending_program_log="$work/pending-program-argv.log"
	cp "$program_log" "$pending_program_log"
	: > "$hardware_log"
	recovery_output=$(run_finalize_make "$signal_result" "$program_variant")
	cmp -s "$pending_program_log" "$program_log" \
		|| { printf 'FAIL: read-only recovery invoked writer arguments\n' >&2; exit 1; }
	mapfile -t recovery_hardware < "$hardware_log"
	[[ "$recovery_output" == *"PIC12F675_TRIM_RECOVERY_RESULT PASS evidence=$signal_result/result.json"* \
		&& -f "$signal_result/result.json" \
		&& ! -e "$signal_result/.recovery-stale" \
		&& "${#recovery_hardware[@]}" -eq 2 \
		&& "${recovery_hardware[0]}" == *"[ -\\?V ]"* \
		&& "${recovery_hardware[1]}" == *"[ -PPIC12F675 -I -GF"*" -R ]"* \
		&& "$recovery_output" != *"Programming PIC12F675"* ]] \
		|| { printf 'FAIL: interrupted transaction recovery was not strictly read-only: %s\n' \
			"$recovery_output" >&2; exit 1; }
	python3 - "$signal_result/result.json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
assert record["status"] == "PASS"
assert record["finalization_mode"] == "recovery"
assert record["release_tag"] is None
assert record["release_source_commit"] is None
assert record["program_exit"] is None
assert record["post_read_exit"] == record["reader_version_exit"] == 0
assert record["programmed_image_bytes_verified"] > 2
PY
	checks=$((checks + 1))

	# An unsealed terminal record is repaired only after complete schema, digest,
	# identity, and status/failure validation. Contradictory evidence stays
	# unsealed and cannot trigger another hardware read.
	contradictory_result="$work/contradictory-terminal-result"
	cp -a "$signal_result" "$contradictory_result"
	chmod 700 "$contradictory_result"
	chmod 600 "$contradictory_result/result.json"
	python3 - "$contradictory_result/result.json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
record["failures"].append("contradictory injected failure")
with open(sys.argv[1], "w", encoding="ascii") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
	: > "$hardware_log"
	if recovery_output=$(run_finalize_make "$contradictory_result" "$program_variant" 2>&1); then
		printf 'FAIL: recovery sealed contradictory terminal evidence\n' >&2
		exit 1
	fi
	contradictory_mode=$(stat -Lc '%a' -- "$contradictory_result")
	[[ "$recovery_output" == *"status contradicts its failures"* \
		&& ! -s "$hardware_log" && "$contradictory_mode" = 700 ]] \
		|| { printf 'FAIL: contradictory terminal evidence was not rejected safely: %s\n' \
			"$recovery_output" >&2; exit 1; }
	checks=$((checks + 1))
	altered_pass_result="$work/altered-pass-terminal-result"
	cp -a "$signal_result" "$altered_pass_result"
	chmod 700 "$altered_pass_result"
	chmod 600 "$altered_pass_result/result.json"
	python3 - "$altered_pass_result/result.json" <<'PY'
import base64
import hashlib
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
post_hex = base64.b64decode(record["post_read_hex_base64"], validate=True)
old = b":040000000000FF23DA"
new = b":040000000300FF23D7"
assert old in post_hex
post_hex = post_hex.replace(old, new, 1)
record["post_read_hex_base64"] = base64.b64encode(post_hex).decode("ascii")
record["post_read_hex_sha256"] = hashlib.sha256(post_hex).hexdigest()
with open(sys.argv[1], "w", encoding="ascii") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
	: > "$hardware_log"
	if recovery_output=$(run_finalize_make "$altered_pass_result" "$program_variant" 2>&1); then
		printf 'FAIL: recovery sealed a PASS with altered programmed bytes\n' >&2
		exit 1
	fi
	altered_pass_mode=$(stat -Lc '%a' -- "$altered_pass_result")
	[[ "$recovery_output" == *"post-program image byte differs at 0x0000"* \
		&& ! -s "$hardware_log" && "$altered_pass_mode" = 700 ]] \
		|| { printf 'FAIL: altered terminal PASS was not replayed safely: %s\n' \
			"$recovery_output" >&2; exit 1; }
	checks=$((checks + 1))

	# Once result.json exists, finalization is immutable and fails before another
	# reader query. Simulate a crash after publication but before sealing; the next
	# invocation validates the terminal record and repairs the directory first.
	chmod 700 "$signal_result"
	: > "$hardware_log"
	if recovery_output=$(run_finalize_make "$signal_result" "$program_variant" 2>&1); then
		printf 'FAIL: recovery replaced an existing final result\n' >&2
		exit 1
	fi
	result_mode=$(stat -Lc '%a' -- "$signal_result")
	[[ "$recovery_output" == *"pending transaction already has result.json"* \
		&& ! -s "$hardware_log" && -f "$signal_result/result.json" \
		&& "$result_mode" = 500 ]] \
		|| { printf 'FAIL: repeated finalization reached hardware or failed for the wrong reason: %s\n' \
			"$recovery_output" >&2; exit 1; }
	if rm -f -- "$signal_result/result.json" 2>/dev/null; then
		printf 'FAIL: terminal recovery directory allowed result.json removal\n' >&2
		exit 1
	fi
	checks=$((checks + 1))

	# A recovery read that finds changed trim, CONFIG, identity, or program bytes
	# still resolves the PENDING state, but exclusively as durable FAIL evidence.
	for spec in \
		"change-osccal|recovery OSCCAL word differs from baseline" \
		"change-bg|recovery BG<1:0> differs from baseline" \
		"wrong-config|post-program CONFIG differs outside factory BG<1:0>" \
		"wrong-program-byte|post-program image byte differs at 0x0000" \
		"change-identity|recovery Device ID differs from baseline" \
		"malformed-recovery-read|contains no complete CONFIG"; do
		recovery_mode=${spec%%|*}
		recovery_reason=${spec#*|}
		recovery_result="$work/recovery-$recovery_mode-result"
		rm -rf "$recovery_result"
		: > "$program_log"
		: > "$hardware_log"
		if program_output=$(PIC12F675_PROGRAMMER_MODE=signal-after-write \
				run_program_make "$PB_BUILD_DIR" "$program_variant" \
				"PIC12F675_BENCH_RESULT=$recovery_result" 2>&1); then
			printf 'FAIL: recovery %s fixture did not interrupt its writer\n' "$recovery_mode" >&2
			exit 1
		fi
		[[ -f "$recovery_result/reservation.json" \
			&& ! -e "$recovery_result/result.json" ]] \
			|| { printf 'FAIL: recovery %s fixture did not leave PENDING evidence\n' \
				"$recovery_mode" >&2; exit 1; }
		: > "$hardware_log"
		if recovery_output=$(PIC12F675_PROGRAMMER_MODE="$recovery_mode" \
				run_finalize_make "$recovery_result" "$program_variant" 2>&1); then
			printf 'FAIL: recovery accepted %s live state\n' "$recovery_mode" >&2
			exit 1
		fi
		[[ "$recovery_output" == *"$recovery_reason"* \
			&& "$recovery_output" == *"PIC12F675_TRIM_RECOVERY_RESULT FAIL evidence=$recovery_result/result.json"* \
			&& -f "$recovery_result/result.json" ]] \
			|| { printf 'FAIL: recovery %s did not publish its durable failure: %s\n' \
				"$recovery_mode" "$recovery_output" >&2; exit 1; }
		python3 - "$recovery_result/result.json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
assert record["status"] == "FAIL"
assert record["finalization_mode"] == "recovery"
assert record["program_exit"] is None
PY
		if [ "$recovery_mode" = malformed-recovery-read ]; then
			chmod 700 "$recovery_result"
			: > "$hardware_log"
			if recovery_output=$(run_finalize_make "$recovery_result" "$program_variant" 2>&1); then
				printf 'FAIL: malformed-read FAIL evidence was finalized twice\n' >&2
				exit 1
			fi
			recovery_mode_bits=$(stat -Lc '%a' -- "$recovery_result")
			[[ "$recovery_output" == *"pending transaction already has result.json"* \
				&& ! -s "$hardware_log" && "$recovery_mode_bits" = 500 ]] \
				|| { printf 'FAIL: legitimate malformed-read FAIL evidence was not self-healed: %s\n' \
					"$recovery_output" >&2; exit 1; }
		fi
		checks=$((checks + 1))
	done

	# The live read immediately before the write must still match the retained
	# baseline. A changed chip/trim cannot reach the programming argv.
	: > "$program_log"
	prewrite_result="$work/prewrite-mismatch-result"
	rm -rf "$prewrite_result"
	if program_output=$(PIC12F675_PROGRAMMER_MODE=prewrite-change \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_BENCH_RESULT=$prewrite_result" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a pre-write trim mismatch\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"current pre-write read differs from baseline: read_hex_sha256, osccal_word, osccal_value"* \
		&& ! -s "$program_log" && ! -e "$prewrite_result" ]] \
		|| { printf 'FAIL: pre-write trim mismatch reached programming or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# A writer that changes either factory value fails after the write but leaves
	# a durable FAIL result containing the before/after values and transcripts.
	for spec in \
		"change-osccal|post-program OSCCAL word differs from baseline|0x34A6|0x1000" \
		"change-bg|post-program BG<1:0> differs from baseline|0x34A5|0x2000" \
		"wrong-program-byte|post-program image byte differs at 0x0000|0x34A5|0x1000" \
		"wrong-config|post-program CONFIG differs outside factory BG<1:0>|0x34A5|0x1000"; do
		mode=${spec%%|*}; rest=${spec#*|}
		reason=${rest%%|*}; rest=${rest#*|}
		post_osccal=${rest%%|*}; post_bg=${rest#*|}
		failure_result="$work/$mode-result"
		rm -rf "$failure_result"
		: > "$program_log"
		if program_output=$(PIC12F675_PROGRAMMER_MODE="$mode" \
				run_program_make "$PB_BUILD_DIR" "$program_variant" \
				"PIC12F675_BENCH_RESULT=$failure_result" 2>&1); then
			printf 'FAIL: PIC12F675 programming accepted %s\n' "$mode" >&2
			exit 1
		fi
		[[ "$program_output" == *"$reason"* \
			&& "$program_output" == *"PIC12F675_TRIM_RESULT FAIL evidence=$failure_result/result.json"* \
			&& -s "$program_log" && -f "$failure_result/result.json" ]] \
			|| { printf 'FAIL: %s did not retain the expected failed readback: %s\n' \
				"$mode" "$program_output" >&2; exit 1; }
		python3 - "$failure_result/result.json" "$post_osccal" "$post_bg" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
assert record["status"] == "FAIL"
assert record["baseline_osccal_word"] == "0x34A5"
assert record["baseline_bg_bits"] == "0x1000"
assert record["post_osccal_word"] == sys.argv[2]
assert record["post_bg_bits"] == sys.argv[3]
PY
		checks=$((checks + 1))
	done

	# Evidence is parsed fail-closed before tools or a private build are reached.
	tampered_evidence="$work/tampered-evidence.json"
	cp "$program_evidence" "$tampered_evidence"
	chmod 600 "$tampered_evidence"
	python3 - "$tampered_evidence" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
record["osccal_word"] = "0x34A6"
with open(sys.argv[1], "w", encoding="ascii") as handle:
    json.dump(record, handle, sort_keys=True)
PY
	: > "$hardware_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_TRIM_EVIDENCE=$tampered_evidence" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted tampered trim evidence\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"baseline osccal_word does not match the retained read HEX"* \
		&& ! -s "$hardware_log" ]] \
		|| { printf 'FAIL: tampered baseline reached hardware or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# A failed post-read is retained as an explicit failed result rather than
	# deleting the only account of a write that may already have erased the chip.
	postread_result="$work/postread-failure-result"
	rm -rf "$postread_result"
	: > "$program_log"
	if program_output=$(PIC12F675_PROGRAMMER_MODE=post-read-fail \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_BENCH_RESULT=$postread_result" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a failed post-program read\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"post-program read exited 92"* \
		&& -s "$program_log" && -f "$postread_result/result.json" ]] \
		|| { printf 'FAIL: post-read failure was not retained correctly: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))
	run_simcal_make >/dev/null

	# A path-qualified ipecmd is identified from its basename without an explicit
	# kind, and the whitespace-bearing snapshot remains one argv element.
	space_variant=tq2_l2_5v_relay
	space_source="$work/program-$space_variant.hex"
	write_program_fixture "$space_source" "$space_variant"
	ipe_dir="$tools/ipe path"
	ipe_programmer="$ipe_dir/ipecmd"
	mkdir -p "$ipe_dir"
	cp "$programmer" "$ipe_programmer"
	chmod 750 "$ipe_programmer"
	: > "$program_log"
	rm -f "$program_capture"
	program_output=$(run_program_make "$PB_BUILD_DIR" "$space_variant" \
			"PIC12F675_PROG=$ipe_programmer" \
			PIC12F675_PROG_TOOL=PK5)
	mapfile -d '' -t program_args < "$program_log"
	[[ "${#program_args[@]}" -eq 4 \
		&& "${program_args[0]}" == -TPPK5 \
		&& "${program_args[1]}" == -PPIC12F675 \
		&& "${program_args[2]}" == -M \
		&& "${program_args[3]}" == -F* ]] \
		|| { printf 'FAIL: renamed ipecmd received unexpected PIC12F675 argv\n' >&2; exit 1; }
	program_snapshot=${program_args[3]#-F}
	[[ "$program_output" == *"PIC12F675_CALIBRATION_CHECK PASS image=$program_snapshot word=0x3FF"* \
		&& "$program_output" == *"selected variant $space_variant from the fresh build matrix"* \
		&& "$program_snapshot" == "$pic12_temp_root"/pic12f675-program.*/"image snapshot.hex" \
		&& ! -e "$program_snapshot" ]] \
		|| { printf 'FAIL: path-qualified ipecmd did not preserve its argv or selected variant: %s\n' \
			"$program_output" >&2; exit 1; }
	cmp -s "$space_source" "$program_capture" \
		|| { printf 'FAIL: ipecmd did not consume the selected shipping-image bytes\n' >&2; exit 1; }
	checks=$((checks + 1))

	# A renamed executable uses the explicitly selected ipecmd dialect.
	renamed_ipe="$tools/renamed ipe programmer"
	cp "$programmer" "$renamed_ipe"
	chmod 750 "$renamed_ipe"
	: > "$program_log"
	program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
		"PIC12F675_PROG=$renamed_ipe" PIC12F675_PROG_KIND=ipecmd)
	mapfile -d '' -t program_args < "$program_log"
	[[ "${#program_args[@]}" -eq 4 && "${program_args[0]}" == -TPPK4 \
		&& "${program_args[1]}" == -PPIC12F675 \
		&& "${program_args[2]}" == -M && "${program_args[3]}" == -F* ]] \
		|| { printf 'FAIL: renamed ipecmd did not receive its explicitly selected argv dialect\n' >&2; exit 1; }
	checks=$((checks + 1))

	# External-image selection is retired rather than allowed to weaken the normal
	# target's fresh-build provenance. Name each hazardous substitution explicitly.
	external_dir="$work/external images"
	mkdir -p "$external_dir"
	minimal_image="$external_dir/minimal call.hex"
	wrong_part_image="$external_dir/wrong part.hex"
	write_calibration_fixture "$minimal_image"
	printf '%s\n' ':040000000028FF21B4' ':02400E009E38DA' ':00000001FF' \
		> "$wrong_part_image"
	for spec in \
		"wrong output variant|${cal_shipping[1]}" \
		"wrong part|$wrong_part_image" \
		"minimal fake CALL image|$minimal_image"; do
		label=${spec%%|*}
		external_image=${spec#*|}
		: > "$program_log"
		if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
				"PIC12F675_PROG_HEX=$external_image" 2>&1); then
			printf 'FAIL: PIC12F675 programming accepted %s through an external-image override\n' "$label" >&2
			exit 1
		fi
		[[ "$program_output" == *"PIC12F675_PROG_HEX is not supported"* \
			&& ! -s "$program_log" ]] \
			|| { printf 'FAIL: %s reached the programmer or failed for the wrong reason: %s\n' \
				"$label" "$program_output" >&2; exit 1; }
		checks=$((checks + 1))
	done

	# Whole-command substitution is rejected before even an unrelated/missing
	# PIC12F675_PROG executable is consulted.
	: > "$program_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
			PIC12F675_PROG="$tools/missing-programmer" \
			"PIC12F675_PROG_CMD=$programmer -PPIC12F675 -F$minimal_image" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a whole-command override\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"PIC12F675_PROG_CMD is not supported"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: whole-command override reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$program_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
			PIC12F675_PROG_KIND=unknown 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted an unknown programmer dialect\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"PIC12F675_PROG_KIND must be exactly pk2cmd or ipecmd"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: unknown programmer dialect reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$program_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_PROG=$ipe_programmer" PIC12F675_PROG_KIND=ipecmd \
			'PIC12F675_PROG_TOOL=PK4 -Fwrong.hex' 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted an invalid ipecmd hardware tool\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"PIC12F675_PROG_TOOL must be exactly PK3, PK4, or PK5"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: invalid ipecmd tool reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# The remaining hostile images are emitted by the private fresh build itself.
	# Every safety-critical CONFIG field must fail its named check before any
	# hardware command; whole-word equality then protects the remaining fields.
	for spec in \
		"bad-fosc|FOSC must be INTRCIO" \
		"bad-wdte|WDTE must be ON" \
		"bad-mclre|MCLRE must be OFF" \
		"bad-boren|BOREN must be ON" \
		"bad-bg|BG must be left ERASED" \
		"bad-full-word|built CONFIG word must equal 0x31CC"; do
		config_mode=${spec%%|*}
		config_reason=${spec#*|}
		: > "$program_log"
		: > "$hardware_log"
		if program_output=$(PIC12F675_PROGRAM_IMAGE_MODE="$config_mode" \
				run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
			printf 'FAIL: PIC12F675 programming accepted CONFIG mode %s\n' "$config_mode" >&2
			exit 1
		fi
		[[ "$program_output" == *"$config_reason"* \
			&& ! -s "$program_log" && ! -s "$hardware_log" ]] \
			|| { printf 'FAIL: CONFIG mode %s reached hardware or failed for the wrong reason: %s\n' \
				"$config_mode" "$program_output" >&2; exit 1; }
		checks=$((checks + 1))
	done

	# A hostile host compiler can still produce an exit-zero executable, but no
	# no-output, near-match, or wrong-image record can satisfy the exact gate.
	for config_mode in no-output near-match wrong-image; do
		: > "$program_log"
		: > "$hardware_log"
		if program_output=$(PIC12F675_CONFIG_MODE="$config_mode" \
				run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
			printf 'FAIL: PIC12F675 programming trusted CONFIG checker mode %s\n' \
				"$config_mode" >&2
			exit 1
		fi
		[[ "$program_output" == *"did not emit its exact image-bound success record"* \
			&& ! -s "$program_log" && ! -s "$hardware_log" ]] \
			|| { printf 'FAIL: CONFIG checker mode %s reached hardware or failed for the wrong reason: %s\n' \
				"$config_mode" "$program_output" >&2; exit 1; }
		checks=$((checks + 1))
	done

	: > "$program_log"
	if program_output=$(PIC12F675_PROGRAM_IMAGE_MODE=overlap \
			run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted overlapping HEX data\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"overlaps its definition"* && ! -s "$program_log" ]] \
		|| { printf 'FAIL: overlapping HEX reached CONFIG/programming or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$program_log"
	if program_output=$(PIC12F675_PROGRAM_IMAGE_MODE=derived \
			run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a derived simulator image at the selected path\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"already programs the calibration word 0x3FF"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: derived image reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$program_log"
	if program_output=$(PIC12F675_PROGRAM_XC8_MODE=symlink \
			run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a symlinked selected image\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"private PIC12F675 programming matrix did not build successfully"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: symlinked image reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	replacement_image="$work/replacement.hex"
	printf '%s\n' ':040000000300FF23D7' ':02400E00CC31B3' ':00000001FF' \
		> "$replacement_image"
	: > "$program_log"
	if program_output=$(PIC12F675_CONFIG_MODE=replace \
			PIC12F675_CONFIG_REPLACEMENT="$replacement_image" \
			run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
		printf 'FAIL: PIC12F675 programming accepted a snapshot replaced during checks\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"private programming snapshot changed during pre-flash checks"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: replaced snapshot reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	# After the final digest the private directory is read/search-only. Even the
	# programmer process cannot replace the path before opening it.
	: > "$program_log"
	rm -f "$program_capture" "$program_late_marker"
	program_output=$(PIC12F675_PROGRAMMER_MODE=replace \
		PIC12F675_PROGRAMMER_REPLACEMENT="$replacement_image" \
		run_program_make "$PB_BUILD_DIR" "$program_variant")
	[[ "$(<"$program_late_marker")" == blocked ]] \
		|| { printf 'FAIL: private snapshot remained replaceable after its final digest\n' >&2; exit 1; }
	cmp -s "$program_source" "$program_capture" \
		|| { printf 'FAIL: late replacement attempt changed programmed snapshot bytes\n' >&2; exit 1; }
	checks=$((checks + 1))

	# Exit status zero is insufficient. Replacing the repository checker itself
	# first with no output and then a near-match record must leave programming
	# unreachable in both cases.
	checker="$repo/test/pic/inject_calibration_word.py"
	mv "$checker" "$work/inject_calibration_word.py"
	cp "$tools/noop-oracle.py" "$checker"
	: > "$program_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
		printf 'FAIL: PIC12F675 programming trusted a no-op calibration checker\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"did not emit its exact success record"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: no-op PIC12F675 checker reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	checks=$((checks + 1))

	cp "$tools/near-match-checker.py" "$checker"
	: > "$program_log"
	if program_output=$(run_program_make "$PB_BUILD_DIR" "$program_variant" 2>&1); then
		printf 'FAIL: PIC12F675 programming trusted a near-match calibration record\n' >&2
		exit 1
	fi
	[[ "$program_output" == *"did not emit its exact success record"* \
		&& ! -s "$program_log" ]] \
		|| { printf 'FAIL: near-match PIC12F675 checker reached the programmer or failed for the wrong reason: %s\n' \
			"$program_output" >&2; exit 1; }
	mv "$work/inject_calibration_word.py" "$checker"
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

	# Release programming composes the same private snapshot transaction with a
	# clean annotated-tag check and the selected digest from signed SHA256SUMS.
	# The signature leaf is synthetic here; production GPG policy is covered by
	# test_release_history.sh.
	release_tag=v1.0.0
	release_dir="$repo/release/$release_tag"
	release_signature_log="$work/pic12f675-release-signature.log"
	mkdir -p "$release_dir"
	cp "$ROOT/.gitignore" "$repo/.gitignore"
	cat > "$repo/scripts/verify-release-signature.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "$0")/release-signing-policy.sh"
printf '%s\0' "$@" >> "${PIC12F675_SIGNATURE_LOG:?}"
[ "${PIC12F675_SIGNATURE_MODE:-pass}" != "fail-${1:-}" ] || {
	printf 'fixture signature rejection\n' >&2
	exit 1
}
case "${1:-}" in
	tag|detached)
		printf 'SIGNATURE-VALID: %s signature made by %s.\n' \
			"$1" "$RELEASE_SIGNING_FINGERPRINT"
		;;
	*) exit 2 ;;
esac
EOF
	chmod 755 "$repo/scripts/verify-release-signature.sh"
	release_images=$(_MAKE_SERIAL_LOCK_HELD="$cal_repo_lock_id" \
		make -s --no-print-directory -C "$repo" print-RELEASE_IMAGES CC=true) \
		|| { printf 'FAIL: could not read release image set for PIC12F675 programming fixture\n' >&2; exit 1; }
	for image in $release_images; do
		case "$image" in
			bypass-pic12f675-cd4053_simple.hex)
				write_program_fixture "$release_dir/$image" cd4053_simple ;;
			bypass-pic12f675-cd4053_with_mute.hex)
				write_program_fixture "$release_dir/$image" cd4053_with_mute ;;
			bypass-pic12f675-tq2_l2_5v_relay.hex)
				write_program_fixture "$release_dir/$image" tq2_l2_5v_relay ;;
			*) printf 'fixture release bytes for %s\n' "$image" > "$release_dir/$image" ;;
		esac
	done
	(
		cd "$release_dir"
		sha256sum $release_images > SHA256SUMS
	)
	printf 'fixture detached signature\n' > "$release_dir/SHA256SUMS.asc"
	git -C "$repo" init -q
	git -C "$repo" config user.name 'PIC Build Test'
	git -C "$repo" config user.email 'pic-build@example.invalid'
	git -C "$repo" add .
	git -C "$repo" -c commit.gpgsign=false commit -qm fixture
	git -C "$repo" tag -a -m fixture "$release_tag"
	release_commit=$(git -C "$repo" rev-parse --verify "refs/tags/$release_tag^{commit}")
	: > "$release_signature_log"
	: > "$program_log"
	: > "$hardware_log"
	release_result="$work/pic12f675-release-program-result"
	rm -rf "$release_result"
	release_output=$(PIC12F675_PROGRAM_TARGET=pic12f675-release-program \
		PIC12F675_SIGNATURE_LOG="$release_signature_log" \
		run_program_make "$PB_BUILD_DIR" "$program_variant" \
		"PIC12F675_RELEASE_TAG=$release_tag" \
		"PIC12F675_BENCH_RESULT=$release_result")
	mapfile -d '' -t program_args < "$program_log"
	[[ "${#program_args[@]}" -eq 5 && "${program_args[1]}" == -F* ]] \
		|| { printf 'FAIL: signed-release target did not reach the guarded writer argv\n' >&2; exit 1; }
	release_snapshot=${program_args[1]#-F}
	release_digest=$(sha256sum "$release_dir/bypass-pic12f675-cd4053_simple.hex")
	release_digest=${release_digest%% *}
	expected_release_check="PIC12F675_RELEASE_IMAGE_CHECK PASS tag=$release_tag variant=$program_variant image=$release_snapshot sha256=$release_digest"
	mapfile -d '' -t release_signature_args < "$release_signature_log"
	[[ "$release_output" == *"PIC12F675_RELEASE_SOURCE_CHECK PASS tag=$release_tag"* \
		&& "$release_output" == *"$expected_release_check"* \
		&& "$release_snapshot" == "$pic12_temp_root"/pic12f675-program.*/"image snapshot.hex" \
		&& ! -e "$release_snapshot" \
		&& "${#release_signature_args[@]}" -eq 9 \
		&& "${release_signature_args[0]}" = tag \
		&& "${release_signature_args[3]}" = tag \
		&& "${release_signature_args[6]}" = detached ]] \
		|| { printf 'FAIL: signed-release programming did not authenticate and bind its snapshot: %s\n' \
			"$release_output" >&2; exit 1; }
	cmp -s "$release_dir/bypass-pic12f675-cd4053_simple.hex" "$program_capture" \
		|| { printf 'FAIL: signed-release writer did not consume the checked release bytes\n' >&2; exit 1; }
	python3 - "$release_result/reservation.json" "$release_result/result.json" \
		"$release_tag" "$release_commit" <<'PY'
import json
import sys
for path in sys.argv[1:3]:
    with open(path, "r", encoding="ascii") as handle:
        record = json.load(handle)
    assert record["release_tag"] == sys.argv[3]
    assert record["release_source_commit"] == sys.argv[4]
PY
	checks=$((checks + 1))

	# If the signed-release writer is interrupted after consuming the image, the
	# PENDING reservation retains the exact tag/source identity. Recovery without
	# that identity fails before hardware; matching recovery revalidates the signed
	# source and retained image before its read-only device operations.
	release_pending="$work/pic12f675-release-pending-result"
	rm -rf "$release_pending"
	: > "$program_log"
	: > "$hardware_log"
	if release_output=$(PIC12F675_PROGRAM_TARGET=pic12f675-release-program \
			PIC12F675_PROGRAMMER_MODE=signal-after-write \
			PIC12F675_SIGNATURE_LOG="$release_signature_log" \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_RELEASE_TAG=$release_tag" \
			"PIC12F675_BENCH_RESULT=$release_pending" 2>&1); then
		printf 'FAIL: interrupted signed-release writer returned success\n' >&2
		exit 1
	fi
	[[ -f "$release_pending/reservation.json" \
		&& ! -e "$release_pending/result.json" ]] \
		|| { printf 'FAIL: interrupted signed-release writer lost its PENDING evidence: %s\n' \
			"$release_output" >&2; exit 1; }
	python3 - "$release_pending/reservation.json" "$release_tag" "$release_commit" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
assert record["release_tag"] == sys.argv[2]
assert record["release_source_commit"] == sys.argv[3]
PY
	: > "$hardware_log"
	if release_output=$(run_finalize_make "$release_pending" "$program_variant" 2>&1); then
		printf 'FAIL: signed-release recovery accepted a missing release identity\n' >&2
		exit 1
	fi
	[[ "$release_output" == *"reservation release identity differs from selected release"* \
		&& ! -s "$hardware_log" && ! -e "$release_pending/result.json" ]] \
		|| { printf 'FAIL: missing release recovery identity reached hardware or failed for the wrong reason: %s\n' \
			"$release_output" >&2; exit 1; }

	# ... and a resolvable but DIFFERENT release tag is rejected by the same
	# comparison, also before any device read. Omission and substitution are the
	# two ways a published recovery command can carry the wrong identity, so both
	# are pinned here.
	git -C "$repo" -c tag.gpgSign=false tag -a -m fixture v9.9.9 "$release_commit"
	: > "$hardware_log"
	if release_output=$(run_finalize_make "$release_pending" "$program_variant" \
			PIC12F675_RELEASE_TAG=v9.9.9 2>&1); then
		printf 'FAIL: signed-release recovery accepted a substituted release identity\n' >&2
		exit 1
	fi
	[[ "$release_output" == *"reservation release identity differs from selected release"* \
		&& ! -s "$hardware_log" && ! -e "$release_pending/result.json" ]] \
		|| { printf 'FAIL: substituted release recovery identity reached hardware or failed for the wrong reason: %s\n' \
			"$release_output" >&2; exit 1; }
	checks=$((checks + 1))

	pending_program_log="$work/release-pending-program-argv.log"
	cp "$program_log" "$pending_program_log"
	: > "$hardware_log"
	release_output=$(PIC12F675_SIGNATURE_LOG="$release_signature_log" \
		run_finalize_make "$release_pending" "$program_variant" \
		"PIC12F675_RELEASE_TAG=$release_tag")
	cmp -s "$pending_program_log" "$program_log" \
		|| { printf 'FAIL: signed-release recovery invoked writer arguments\n' >&2; exit 1; }
	[[ "$release_output" == *"PIC12F675_RELEASE_SOURCE_CHECK PASS tag=$release_tag"* \
		&& "$release_output" == *"PIC12F675_RELEASE_IMAGE_CHECK PASS tag=$release_tag variant=$program_variant image=$release_pending/image.hex"* \
		&& "$release_output" == *"PIC12F675_TRIM_RECOVERY_RESULT PASS evidence=$release_pending/result.json"* \
		&& -f "$release_pending/result.json" ]] \
		|| { printf 'FAIL: signed-release recovery did not revalidate source/image provenance: %s\n' \
			"$release_output" >&2; exit 1; }
	python3 - "$release_pending/result.json" "$release_tag" "$release_commit" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="ascii") as handle:
    record = json.load(handle)
assert record["status"] == "PASS"
assert record["finalization_mode"] == "recovery"
assert record["release_tag"] == sys.argv[2]
assert record["release_source_commit"] == sys.argv[3]
PY
	checks=$((checks + 1))

	# A tracked mutation after preflight fails the target's internal clean-source
	# check before any reader or writer operation.
	source_backup="$work/bypass_pure.c.release-backup"
	cp "$repo/src/bypass_pure.c" "$source_backup"
	printf '\n/* tracked release-program mutation */\n' >> "$repo/src/bypass_pure.c"
	: > "$program_log"
	: > "$hardware_log"
	if release_output=$(PIC12F675_PROGRAM_TARGET=pic12f675-release-program \
			PIC12F675_SIGNATURE_LOG="$release_signature_log" \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_RELEASE_TAG=$release_tag" 2>&1); then
		printf 'FAIL: signed-release programming accepted a tracked source mutation\n' >&2
		exit 1
	fi
	[[ "$release_output" == *"release-programming worktree is not clean"* \
		&& ! -s "$program_log" && ! -s "$hardware_log" ]] \
		|| { printf 'FAIL: tracked release mutation reached hardware or failed for the wrong reason: %s\n' \
			"$release_output" >&2; exit 1; }
	cp "$source_backup" "$repo/src/bypass_pure.c"
	git -C "$repo" diff --quiet \
		|| { printf 'FAIL: release source fixture did not restore cleanly\n' >&2; exit 1; }
	checks=$((checks + 1))

	# Valid Intel HEX with safe calibration and CONFIG fields still cannot pass if
	# its program bytes differ from the selected signed digest.
	: > "$program_log"
	: > "$hardware_log"
	if release_output=$(PIC12F675_PROGRAM_TARGET=pic12f675-release-program \
			PIC12F675_PROGRAM_IMAGE_MODE=byte-different \
			PIC12F675_SIGNATURE_LOG="$release_signature_log" \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_RELEASE_TAG=$release_tag" 2>&1); then
		printf 'FAIL: signed-release programming accepted byte-different compiler output\n' >&2
		exit 1
	fi
	[[ "$release_output" == *"PIC12F675_CALIBRATION_CHECK PASS"* \
		&& "$release_output" == *"candidate image does not match the signed release image set"* \
		&& ! -s "$program_log" && ! -s "$hardware_log" ]] \
		|| { printf 'FAIL: byte-different release image reached hardware or failed for the wrong reason: %s\n' \
			"$release_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$program_log"
	: > "$hardware_log"
	if release_output=$(PIC12F675_PROGRAM_TARGET=pic12f675-release-program \
			PIC12F675_SIGNATURE_LOG="$release_signature_log" \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			PIC12F675_RELEASE_TAG=v1.0.1 2>&1); then
		printf 'FAIL: signed-release programming accepted a mismatched release tag\n' >&2
		exit 1
	fi
	[[ "$release_output" == *"release tag does not exist: v1.0.1"* \
		&& ! -s "$program_log" && ! -s "$hardware_log" ]] \
		|| { printf 'FAIL: mismatched release tag reached hardware or failed for the wrong reason: %s\n' \
			"$release_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$program_log"
	: > "$hardware_log"
	inside_result="$repo/pic12f675-release-result"
	if release_output=$(PIC12F675_PROGRAM_TARGET=pic12f675-release-program \
			PIC12F675_SIGNATURE_LOG="$release_signature_log" \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_RELEASE_TAG=$release_tag" \
			"PIC12F675_BENCH_RESULT=$inside_result" 2>&1); then
		printf 'FAIL: signed-release programming accepted worktree-local evidence\n' >&2
		exit 1
	fi
	[[ "$release_output" == *"baseline and result paths must be outside the worktree"* \
		&& ! -s "$program_log" && ! -s "$hardware_log" && ! -e "$inside_result" ]] \
		|| { printf 'FAIL: worktree-local release evidence reached hardware or failed for the wrong reason: %s\n' \
			"$release_output" >&2; exit 1; }
	checks=$((checks + 1))

	: > "$program_log"
	: > "$hardware_log"
	if release_output=$(PIC12F675_PROGRAM_TARGET=pic12f675-release-program \
			PIC12F675_SIGNATURE_MODE=fail-detached \
			PIC12F675_SIGNATURE_LOG="$release_signature_log" \
			run_program_make "$PB_BUILD_DIR" "$program_variant" \
			"PIC12F675_RELEASE_TAG=$release_tag" 2>&1); then
		printf 'FAIL: signed-release programming accepted a bad checksum signature\n' >&2
		exit 1
	fi
	[[ "$release_output" == *"release checksum signature verification failed"* \
		&& ! -s "$program_log" && ! -s "$hardware_log" ]] \
		|| { printf 'FAIL: bad release checksum signature reached hardware or failed for the wrong reason: %s\n' \
			"$release_output" >&2; exit 1; }
	checks=$((checks + 1))
	[ ! -e "$pic12_temp_cleanup_failure" ] \
		|| { printf 'FAIL: an expected-failure scenario masked leaked PIC12F675 transient data\n' >&2; exit 1; }
fi

[ -z "$expected_checks" ] || [ "$checks" -eq "$expected_checks" ] \
	|| { printf 'FAIL: canonical %s build validation ran %d checks, expected %d\n' \
		"$PB_TARGET" "$checks" "$expected_checks" >&2; exit 1; }
printf '%s build validation: %d checks, 0 failures\n' "$PB_LABEL" "$checks"
