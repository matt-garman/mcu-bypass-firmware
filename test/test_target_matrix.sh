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
readonly -a TM_REQUIRED_PROFILES=(
	pic10f322-target
	pic10f320-target
	pic12f675-target
	pic10f320-host
	attiny202-target
)
readonly -a TM_CANONICAL_VARIANTS=(
	cd4053_simple
	cd4053_with_mute
	tq2_l2_5v_relay
)

tm_validate_profile_request() {
	local name required
	local -a missing=()
	local -A known=() seen=()
	[ "$#" -gt 0 ] \
		|| { printf 'FAIL: target-matrix profile request must not be empty\n' >&2; return 2; }
	for required in "${TM_REQUIRED_PROFILES[@]}"; do known[$required]=1; done
	for name in "$@"; do
		[ -n "$name" ] \
			|| { printf 'FAIL: target-matrix profile request contains an empty name\n' >&2; return 2; }
		[ -n "${known[$name]+yes}" ] \
			|| { printf 'FAIL: target-matrix profile request contains unknown name: %s\n' "$name" >&2; return 2; }
		[ -z "${seen[$name]+yes}" ] \
			|| { printf 'FAIL: target-matrix profile request contains duplicate name: %s\n' "$name" >&2; return 2; }
		seen[$name]=1
	done
	for required in "${TM_REQUIRED_PROFILES[@]}"; do
		[ -n "${seen[$required]+yes}" ] || missing+=("$required")
	done
	[ "${#missing[@]}" -eq 0 ] \
		|| { printf 'FAIL: target-matrix profile request is incomplete; missing: %s\n' \
			"${missing[*]}" >&2; return 2; }
}

tm_expect_profile_reject() {
	local label=$1
	shift
	if tm_validate_profile_request "$@" >/dev/null 2>&1; then
		printf 'FAIL: target-matrix profile validator accepted %s request\n' "$label" >&2
		exit 1
	fi
}

if [ "${1:-}" != --run-profile ]; then
	tm_validate_profile_request "$@" || exit
	tm_expect_profile_reject empty
	tm_expect_profile_reject explicit-empty "${TM_REQUIRED_PROFILES[@]}" ""
	tm_expect_profile_reject unknown "${TM_REQUIRED_PROFILES[@]}" unknown
	tm_expect_profile_reject duplicate "${TM_REQUIRED_PROFILES[@]}" pic10f322-target
	tm_expect_profile_reject incomplete \
		pic10f322-target pic10f320-target pic12f675-target pic10f320-host
	for profile in "${TM_REQUIRED_PROFILES[@]}"; do
		"$0" --run-profile "$profile"
	done
	printf 'target-matrix profile request validation: 5 checks, 0 failures\n'
	exit 0
fi

[ "$#" -eq 2 ] && [ -n "$2" ] \
	|| { printf 'FAIL: internal target-matrix profile worker request is malformed\n' >&2; exit 2; }
readonly TM_PROFILE=$2

# Common marker policy. Each named profile below owns its targets/selectors;
# the canonical variant set remains an independent test literal.
TM_SUPPORTED="${TM_CANONICAL_VARIANTS[*]}"
TM_SUBSET=${TM_CANONICAL_VARIANTS[1]}
TM_UNSUPPORTED=unknown
TM_CHECK_SENTINELS=1
TM_FAULT_TARGET=pic10f322-test-fault
TM_FAULT_VARIANT_ARG=PIC10F322_FAULT_VARIANT
TM_LOCKSTEP_TARGET=pic10f322-test-lockstep
TM_LOCKSTEP_VARIANT_ARG=PIC10F322_LOCKSTEP_VARIANT
TM_IO_TARGET=pic10f322-test-io
TM_IO_VARIANT_ARG=PIC10F322_IO_VARIANT
TM_FAULT_MARKER='FAULT-INJECT PASS'
TM_LOCKSTEP_MARKER='LOCK-STEP PASS'
TM_IO_MARKER='TARGET-IO PASS'
TM_FAULT_MARKER_COUNT=1
TM_LOCKSTEP_MARKER_COUNT=1
TM_IO_MARKER_COUNT=1
TM_IO_EXTRA_MARKER=
TM_IO_EXTRA_MARKER_COUNT=0
TM_AGGREGATE_LANES=0
TM_EXACT_FAULT_CHECKS=38
TM_EXACT_RESULTS=0
TM_PIC12F675=0
case "$TM_PROFILE" in
	pic10f322-target)
		TM_LABEL=PIC
		TM_TARGET=pic10f322-test-target-variants
		TM_PER_VARIANT_TARGET=pic10f322-test-target
		TM_VARIANTS_VAR=VARIANTS
		TM_VARIANT_ARG=PIC10F322_TARGET_VARIANT
		;;
	pic10f320-target)
		TM_LABEL=PIC10F320
		TM_TARGET=pic10f320-test-target-variants
		TM_PER_VARIANT_TARGET=pic10f320-test-target
		TM_VARIANTS_VAR=PIC10F320_VARIANTS_ALL
		TM_VARIANT_ARG=PIC10F320_TARGET_VARIANT
		TM_UNSUPPORTED=tmux4053-simple
		TM_FAULT_TARGET=pic10f320-test-fault-target
		TM_FAULT_VARIANT_ARG=PIC10F320_FAULT_VARIANT
		TM_LOCKSTEP_TARGET=pic10f320-test-lockstep
		TM_LOCKSTEP_VARIANT_ARG=PIC10F320_LOCKSTEP_VARIANT
		TM_IO_TARGET=pic10f320-test-io
		TM_IO_VARIANT_ARG=PIC10F320_IO_VARIANT
		;;
	pic12f675-target)
		TM_LABEL=PIC12F675
		TM_TARGET=pic12f675-test-target-variants
		TM_PER_VARIANT_TARGET=pic12f675-test-target
		TM_VARIANTS_VAR=VARIANTS
		TM_VARIANT_ARG=PIC12F675_TARGET_VARIANT
		TM_UNSUPPORTED=tmux4053-simple
		TM_FAULT_TARGET=pic12f675-test-fault
		TM_FAULT_VARIANT_ARG=PIC12F675_FAULT_VARIANT
		TM_LOCKSTEP_TARGET=pic12f675-test-lockstep
		TM_LOCKSTEP_VARIANT_ARG=PIC12F675_LOCKSTEP_VARIANT
		TM_IO_TARGET=pic12f675-test-io
		TM_IO_VARIANT_ARG=PIC12F675_IO_VARIANT
		TM_EXACT_RESULTS=1
		TM_PIC12F675=1
		;;
	pic10f320-host)
		TM_LABEL='PIC10F320 host'
		TM_TARGET=pic10f320-test-host-variants
		TM_PER_VARIANT_TARGET=pic10f320-test-host
		TM_VARIANTS_VAR=PIC10F320_VARIANTS_ALL
		TM_VARIANT_ARG=PIC10F320_VARIANT
		TM_UNSUPPORTED=tmux4053-simple
		TM_CHECK_SENTINELS=0
		;;
	attiny202-target)
		TM_LABEL=ATtiny202
		TM_TARGET=attiny202-test-target
		TM_PER_VARIANT_TARGET=__unused__
		TM_VARIANTS_VAR=VARIANTS
		TM_VARIANT_ARG=__unused__
		TM_FAULT_TARGET=attiny202-sim
		TM_LOCKSTEP_TARGET=attiny202-fault
		TM_IO_TARGET=attiny202-lockstep
		TM_FAULT_VARIANT_ARG=__unused__
		TM_LOCKSTEP_VARIANT_ARG=__unused__
		TM_IO_VARIANT_ARG=__unused__
		TM_FAULT_MARKER='SIM PASS'
		TM_LOCKSTEP_MARKER='FAULT PASS'
		TM_IO_MARKER='LOCKSTEP PASS'
		TM_FAULT_MARKER_COUNT=3
		TM_LOCKSTEP_MARKER_COUNT=3
		TM_IO_MARKER_COUNT=3
		TM_IO_EXTRA_MARKER=co-simulated
		TM_IO_EXTRA_MARKER_COUNT=6
		TM_AGGREGATE_LANES=1
		;;
	*) printf 'FAIL: unknown internal target-matrix profile: %s\n' "$TM_PROFILE" >&2; exit 2 ;;
esac
for value in "$TM_LABEL" "$TM_TARGET" "$TM_PER_VARIANT_TARGET" \
		"$TM_VARIANTS_VAR" "$TM_VARIANT_ARG" "$TM_SUPPORTED" "$TM_SUBSET" \
		"$TM_UNSUPPORTED" "$TM_FAULT_TARGET" "$TM_FAULT_VARIANT_ARG" \
		"$TM_LOCKSTEP_TARGET" "$TM_LOCKSTEP_VARIANT_ARG" "$TM_IO_TARGET" \
		"$TM_IO_VARIANT_ARG" "$TM_FAULT_MARKER" "$TM_LOCKSTEP_MARKER" \
		"$TM_IO_MARKER"; do
	[ -n "$value" ] || { printf 'FAIL: incomplete internal target-matrix profile: %s\n' "$TM_PROFILE" >&2; exit 2; }
done
for value in "$TM_CHECK_SENTINELS" "$TM_AGGREGATE_LANES" \
		"$TM_EXACT_RESULTS" "$TM_PIC12F675"; do
	[[ "$value" =~ ^[01]$ ]] \
		|| { printf 'FAIL: invalid boolean in target-matrix profile: %s\n' "$TM_PROFILE" >&2; exit 2; }
done

test_temp_root=${TMPDIR:-${XDG_RUNTIME_DIR:-${HOME:?HOME is required when TMPDIR and XDG_RUNTIME_DIR are unset}}}
work=$(mktemp -d -- "$test_temp_root/test-target-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake_make="$work/fake-make"
log="$work/make.log"
checks=0
read -r -a supported <<<"$TM_SUPPORTED"
read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] \
	|| { printf 'FAIL: PROJECT_MAKE must name a Make command\n' >&2; exit 1; }
real_make=$(command -v make)
matrix_contract_args=()
expected_matrix_record=
if [ "$TM_PIC12F675" -eq 1 ]; then
	matrix_dir="$work/pic12f675-matrix"
	mkdir -p "$matrix_dir/simcal"
	for variant in "${TM_CANONICAL_VARIANTS[@]}"; do
		stem="bypass-pic12f675-$variant"
		printf 'shipping %s\n' "$variant" > "$matrix_dir/$stem.hex"
		printf 'assembly %s\n' "$variant" > "$matrix_dir/$stem.s"
		printf 'symbols %s\n' "$variant" > "$matrix_dir/$stem.sym"
		printf 'simcal %s\n' "$variant" > "$matrix_dir/simcal/${stem}_simcal.hex"
	done
	expected_matrix_record=$(python3 "$ROOT/test/pic/pic12f675_matrix_evidence.py" record \
		--build-dir "$matrix_dir" --fw-base bypass --tag pic12f675)
	matrix_contract_args=(--old-file=_pic12f675-qualify-matrix \
		"PIC12F675_BUILD_DIR=$matrix_dir")
fi

cat > "$fake_make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${TM_ENTER_REAL_MAKE:-0}" -eq 1 ]; then
	export TM_ENTER_REAL_MAKE=0
	exec -a "$0" "${REAL_PROJECT_MAKE:?}" "$@"
fi

target=
marker=
count=0
for arg in "$@"; do
	case "$arg" in
		_pic12f675-qualify-matrix)
			: > "${MATRIX_COMBINED_QUALIFIED_MARKER:?}"
			exit 0
			;;
		"${FAKE_PER_VARIANT_TARGET:?}") target=$arg; marker=; count=0 ;;
		"${FAKE_FAULT_TARGET:?}") target=$arg; marker=${FAKE_FAULT_MARKER:?}; count=${FAKE_FAULT_MARKER_COUNT:?} ;;
		"${FAKE_LOCKSTEP_TARGET:?}") target=$arg; marker=${FAKE_LOCKSTEP_MARKER:?}; count=${FAKE_LOCKSTEP_MARKER_COUNT:?} ;;
		"${FAKE_IO_TARGET:?}") target=$arg; marker=${FAKE_IO_MARKER:?}; count=${FAKE_IO_MARKER_COUNT:?} ;;
	esac
done
if [ -z "$target" ]; then
	exec -a "$0" "${REAL_PROJECT_MAKE:?}" "$@"
fi
printf 'CALL' >> "${FAKE_MAKE_LOG:?}"
printf ' <%s>' "$@" >> "$FAKE_MAKE_LOG"
printf '\n' >> "$FAKE_MAKE_LOG"
if [ -n "$target" ] && [ "${FAKE_OMIT_MARKER:-}" != "$target" ]; then
	if [ "${FAKE_EXACT_RESULTS:-0}" -eq 1 ] && [ -n "$marker" ]; then
		case "$target" in
			"$FAKE_FAULT_TARGET") lane=fault; checks=${FAKE_EXACT_FAULT_CHECKS:?} ;;
			"$FAKE_LOCKSTEP_TARGET") lane=lockstep; checks=3005 ;;
			"$FAKE_IO_TARGET") lane=io; checks=26 ;;
		esac
		printf '%s: %s checks, 0 failures\n' "$marker" "$checks"
		printf 'PIC_TARGET_RESULT format=1 device=pic12f675 lane=%s variant=%s status=pass checks=%s failures=0\n' \
			"$lane" "${FAKE_RESULT_VARIANT:?}" "$checks"
	else
		i=0
		while [ "$i" -lt "$count" ]; do printf '%s\n' "$marker"; i=$((i + 1)); done
	fi
	if [ "$target" = "$FAKE_IO_TARGET" ] && [ -n "${FAKE_IO_EXTRA_MARKER:-}" ] \
			&& [ "${FAKE_OMIT_EXTRA:-0}" -ne 1 ]; then
		i=0
		while [ "$i" -lt "${FAKE_IO_EXTRA_MARKER_COUNT:?}" ]; do
			printf '%s\n' "$FAKE_IO_EXTRA_MARKER"
			i=$((i + 1))
		done
	fi
fi
EOF
chmod 750 "$fake_make"

run_matrix() {
	local matrix=$1
	local omit_marker=${2:-}
	local omit_extra=${3:-0}
	local selector=${4-__NONE__}
	local matrix_arg=() selector_arg=()
	if [ "$matrix" != __DEFAULT__ ]; then
		matrix_arg+=("$TM_VARIANTS_VAR=$matrix")
	fi
	if [ "$selector" != __NONE__ ]; then
		selector_arg+=("$TM_VARIANT_ARG=$selector")
	fi
	: > "$log"
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE "$TM_VARIANTS_VAR"
		FAKE_MAKE_LOG="$log" \
		REAL_PROJECT_MAKE="$real_make" TM_ENTER_REAL_MAKE=1 \
		FAKE_PER_VARIANT_TARGET="$TM_PER_VARIANT_TARGET" \
		FAKE_FAULT_TARGET="$TM_FAULT_TARGET" \
		FAKE_LOCKSTEP_TARGET="$TM_LOCKSTEP_TARGET" \
		FAKE_IO_TARGET="$TM_IO_TARGET" \
		FAKE_FAULT_MARKER="$TM_FAULT_MARKER" \
		FAKE_LOCKSTEP_MARKER="$TM_LOCKSTEP_MARKER" \
		FAKE_IO_MARKER="$TM_IO_MARKER" \
		FAKE_FAULT_MARKER_COUNT="$TM_FAULT_MARKER_COUNT" \
		FAKE_LOCKSTEP_MARKER_COUNT="$TM_LOCKSTEP_MARKER_COUNT" \
		FAKE_IO_MARKER_COUNT="$TM_IO_MARKER_COUNT" \
		FAKE_IO_EXTRA_MARKER="$TM_IO_EXTRA_MARKER" \
		FAKE_IO_EXTRA_MARKER_COUNT="$TM_IO_EXTRA_MARKER_COUNT" \
		FAKE_EXACT_FAULT_CHECKS="$TM_EXACT_FAULT_CHECKS" \
		FAKE_OMIT_MARKER="$omit_marker" \
		FAKE_OMIT_EXTRA="$omit_extra" \
		FAKE_EXACT_RESULTS="$TM_EXACT_RESULTS" \
		FAKE_RESULT_VARIANT="$TM_SUBSET" \
		"$fake_make" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" PROJECT_MAKE=true "${matrix_contract_args[@]}" \
			"${matrix_arg[@]}" "${selector_arg[@]}" "$TM_TARGET"
	)
}

run_target() {
	local omit_marker=${1:-}
	: > "$log"
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE "$TM_VARIANT_ARG"
		FAKE_MAKE_LOG="$log" \
		REAL_PROJECT_MAKE="$real_make" TM_ENTER_REAL_MAKE=1 \
		FAKE_PER_VARIANT_TARGET="$TM_PER_VARIANT_TARGET" \
		FAKE_FAULT_TARGET="$TM_FAULT_TARGET" \
		FAKE_LOCKSTEP_TARGET="$TM_LOCKSTEP_TARGET" \
		FAKE_IO_TARGET="$TM_IO_TARGET" \
		FAKE_FAULT_MARKER="$TM_FAULT_MARKER" \
		FAKE_LOCKSTEP_MARKER="$TM_LOCKSTEP_MARKER" \
		FAKE_IO_MARKER="$TM_IO_MARKER" \
		FAKE_FAULT_MARKER_COUNT="$TM_FAULT_MARKER_COUNT" \
		FAKE_LOCKSTEP_MARKER_COUNT="$TM_LOCKSTEP_MARKER_COUNT" \
		FAKE_IO_MARKER_COUNT="$TM_IO_MARKER_COUNT" \
		FAKE_IO_EXTRA_MARKER="$TM_IO_EXTRA_MARKER" \
		FAKE_IO_EXTRA_MARKER_COUNT="$TM_IO_EXTRA_MARKER_COUNT" \
		FAKE_EXACT_FAULT_CHECKS="$TM_EXACT_FAULT_CHECKS" \
		FAKE_OMIT_MARKER="$omit_marker" \
		FAKE_EXACT_RESULTS="$TM_EXACT_RESULTS" \
		FAKE_RESULT_VARIANT="$TM_SUBSET" \
		"$fake_make" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" PROJECT_MAKE=true "${matrix_contract_args[@]}" \
			"$TM_VARIANT_ARG=$TM_SUBSET" \
			"$TM_PER_VARIANT_TARGET"
	)
}

expect_accept() {
	local label=$1 matrix=$2
	shift 2
	local expected=("$@") output i
	if ! output=$(run_matrix "$matrix" 2>&1); then
		printf 'FAIL: %s matrix was rejected: %s\n' "$label" "$output" >&2
		exit 1
	fi
	[[ "$output" == *"validated for all variants"* ]] \
		|| { printf 'FAIL: %s matrix omitted the PASS marker\n' "$label" >&2; exit 1; }
	if [ -n "$expected_matrix_record" ]; then
		[[ "$output" == *"$expected_matrix_record"* ]] \
			|| { printf 'FAIL: %s matrix PASS omitted its retained hash record\n' "$label" >&2; exit 1; }
	fi
	mapfile -t calls < "$log"
	[ "${#calls[@]}" -eq "${#expected[@]}" ] \
		|| { printf 'FAIL: %s matrix ran %d variants, expected %d\n' \
			"$label" "${#calls[@]}" "${#expected[@]}" >&2; exit 1; }
	for i in "${!expected[@]}"; do
		if [ "$TM_AGGREGATE_LANES" -eq 1 ]; then
			[[ "${calls[$i]}" == *"<${expected[$i]}>"* ]] \
				|| { printf 'FAIL: %s matrix lane %d was wrong: %s\n' \
					"$label" "$i" "${calls[$i]}" >&2; exit 1; }
		else
			[[ "${calls[$i]}" == *"<$TM_VARIANT_ARG=${expected[$i]}>"* \
				&& "${calls[$i]}" == *"<$TM_PER_VARIANT_TARGET>"* ]] \
				|| { printf 'FAIL: %s matrix call %d was wrong: %s\n' \
					"$label" "$i" "${calls[$i]}" >&2; exit 1; }
		fi
		if [ "$TM_PIC12F675" -eq 1 ]; then
			[[ "${calls[$i]}" == *"<--old-file=_pic12f675-qualify-matrix>"* ]] \
				|| { printf 'FAIL: %s matrix call %d did not suppress requalification: %s\n' \
					"$label" "$i" "${calls[$i]}" >&2; exit 1; }
		fi
	done
	checks=$((checks + 1))
}

expect_reject() {
	local label=$1 matrix=$2 marker=$3 output
	if output=$(run_matrix "$matrix" 2>&1); then
		printf 'FAIL: %s matrix was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$marker"* ]] \
		|| { printf 'FAIL: %s matrix reported the wrong error: %s\n' "$label" "$output" >&2; exit 1; }
	[ ! -s "$log" ] \
		|| { printf 'FAIL: %s matrix invoked a variant before rejection\n' "$label" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_selector_reject() {
	local label=$1 selector=$2 marker=$3 output
	if output=$(run_matrix __DEFAULT__ "" 0 "$selector" 2>&1); then
		printf 'FAIL: %s selector was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$marker"* ]] \
		|| { printf 'FAIL: %s selector reported the wrong error: %s\n' \
			"$label" "$output" >&2; exit 1; }
	[ ! -s "$log" ] \
		|| { printf 'FAIL: %s selector invoked a variant before rejection\n' \
			"$label" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_combined_selector_reject() {
	local selector=$1 marker=$2 output qualified_marker="$work/combined-qualified"
	: > "$log"
	rm -f "$qualified_marker"
	if output=$(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE
		FAKE_MAKE_LOG="$log" \
		REAL_PROJECT_MAKE="$real_make" TM_ENTER_REAL_MAKE=1 \
		FAKE_PER_VARIANT_TARGET="$TM_PER_VARIANT_TARGET" \
		FAKE_FAULT_TARGET="$TM_FAULT_TARGET" \
		FAKE_LOCKSTEP_TARGET="$TM_LOCKSTEP_TARGET" \
		FAKE_IO_TARGET="$TM_IO_TARGET" \
		MATRIX_COMBINED_QUALIFIED_MARKER="$qualified_marker" \
		"$fake_make" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" PROJECT_MAKE=true \
			PIC_CC=true "PIC12F675_BUILD_DIR=$matrix_dir" \
			"$TM_VARIANT_ARG=$selector" \
			pic12f675-test pic12f675-test-target-variants 2>&1
	); then
		printf 'FAIL: combined PIC12F675 graph accepted invalid selector\n' >&2
		exit 1
	fi
	[[ "$output" == *"$marker"* \
		&& ! -e "$qualified_marker" \
		&& ! -s "$log" ]] \
		|| { printf 'FAIL: combined selector was not rejected before qualification/consumers: %s\n' \
			"$output" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_sentinels() {
	local output i
	local targets=("$TM_FAULT_TARGET" "$TM_LOCKSTEP_TARGET" "$TM_IO_TARGET")
	local variant_args=("$TM_FAULT_VARIANT_ARG" "$TM_LOCKSTEP_VARIANT_ARG" "$TM_IO_VARIANT_ARG")
	local markers=("$TM_FAULT_MARKER" "$TM_LOCKSTEP_MARKER" "$TM_IO_MARKER")

	if [ "$TM_AGGREGATE_LANES" -eq 1 ]; then
		for i in "${!targets[@]}"; do
			if output=$(run_matrix __DEFAULT__ "${targets[$i]}" 2>&1); then
				printf 'FAIL: %s matrix accepted missing %s\n' \
					"$TM_LABEL" "${markers[$i]}" >&2
				exit 1
			fi
			[[ "$output" == *"did not report '${markers[$i]}'"* ]] \
				|| { printf 'FAIL: %s matrix reported the wrong missing-marker error: %s\n' \
					"$TM_LABEL" "$output" >&2; exit 1; }
			checks=$((checks + 1))
		done
		if [ -n "$TM_IO_EXTRA_MARKER" ]; then
			if output=$(run_matrix __DEFAULT__ "" 1 2>&1); then
				printf 'FAIL: %s matrix accepted missing %s\n' \
					"$TM_LABEL" "$TM_IO_EXTRA_MARKER" >&2
				exit 1
			fi
			[[ "$output" == *"did not report '$TM_IO_EXTRA_MARKER'"* ]] \
				|| { printf 'FAIL: %s matrix reported the wrong extra-marker error: %s\n' \
					"$TM_LABEL" "$output" >&2; exit 1; }
			checks=$((checks + 1))
		fi
		return
	fi

	if ! output=$(run_target 2>&1); then
		printf 'FAIL: %s complete target aggregate was rejected: %s\n' "$TM_LABEL" "$output" >&2
		exit 1
	fi
	[[ "$output" == *"PASS (variant $TM_SUBSET)"* ]] \
		|| { printf 'FAIL: %s target aggregate omitted its PASS marker\n' "$TM_LABEL" >&2; exit 1; }
	if [ -n "$expected_matrix_record" ]; then
		[[ "$output" == *"$expected_matrix_record"* ]] \
			|| { printf 'FAIL: %s target aggregate omitted its retained hash record\n' \
				"$TM_LABEL" >&2; exit 1; }
	fi
	mapfile -t calls < "$log"
	[ "${#calls[@]}" -eq 3 ] \
		|| { printf 'FAIL: %s target aggregate ran %d lanes, expected 3\n' \
			"$TM_LABEL" "${#calls[@]}" >&2; exit 1; }
	for i in "${!targets[@]}"; do
		[[ "${calls[$i]}" == *"<${targets[$i]}>"* \
			&& "${calls[$i]}" == *"<${variant_args[$i]}=$TM_SUBSET>"* ]] \
			|| { printf 'FAIL: %s target lane %d was wrong: %s\n' \
				"$TM_LABEL" "$i" "${calls[$i]}" >&2; exit 1; }
	done
	checks=$((checks + 1))

	for i in "${!targets[@]}"; do
		if output=$(run_target "${targets[$i]}" 2>&1); then
			printf 'FAIL: %s target aggregate accepted missing %s\n' \
				"$TM_LABEL" "${markers[$i]}" >&2
			exit 1
		fi
		if [ "$TM_PIC12F675" -eq 1 ]; then
			[[ "$output" == *"did not report one exact terminal result"* ]] \
				|| { printf 'FAIL: %s target aggregate reported the wrong strict-result error: %s\n' \
					"$TM_LABEL" "$output" >&2; exit 1; }
		else
			[[ "$output" == *"did not report '${markers[$i]}'"* ]] \
				|| { printf 'FAIL: %s target aggregate reported the wrong missing-marker error: %s\n' \
					"$TM_LABEL" "$output" >&2; exit 1; }
		fi
		checks=$((checks + 1))
	done
}

if [ "$TM_AGGREGATE_LANES" -eq 1 ]; then
	expect_accept default __DEFAULT__ "$TM_FAULT_TARGET" "$TM_LOCKSTEP_TARGET" "$TM_IO_TARGET"
else
	expect_accept default __DEFAULT__ "${supported[@]}"
fi
expect_reject incomplete "$TM_SUBSET" \
	"$TM_VARIANTS_VAR must contain every supported name"
expect_reject empty "" "$TM_VARIANTS_VAR must not be empty"
expect_reject duplicate "$TM_SUPPORTED ${supported[0]}" \
	"$TM_VARIANTS_VAR must not contain duplicate names"
expect_reject unsupported "$TM_SUPPORTED $TM_UNSUPPORTED" \
	"$TM_VARIANTS_VAR contains unsupported names"

if [ "$TM_PIC12F675" -eq 1 ]; then
	expect_selector_reject empty-target-selector "" \
		"$TM_VARIANT_ARG is empty"
	expect_selector_reject multi-target-selector "${supported[0]} ${supported[1]}" \
		"names more than one value"
	expect_selector_reject unsupported-target-selector "$TM_UNSUPPORTED" \
		"$TM_VARIANT_ARG is not supported"
	expect_combined_selector_reject "$TM_UNSUPPORTED" \
		"$TM_VARIANT_ARG is not supported"
fi

if [ "$TM_CHECK_SENTINELS" -eq 1 ]; then
	expect_sentinels
fi

printf '%s target-variant matrix validation: %d checks, 0 failures\n' "$TM_LABEL" "$checks"
