#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-target-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake_make="$work/fake-make"
log="$work/make.log"
checks=0
# Parameterized so ONE regression covers both PIC targets (merge plan §4: FOLD
# the shared-name harnesses rather than forking them). In addition to the matrix
# guard, each real-target invocation must require explicit fault, lock-step, and
# I/O completion markers. The host-only PIC10F320 invocation disables that part.
TM_LABEL=${TM_LABEL:-PIC}
TM_TARGET=${TM_TARGET:-pic-test-target-variants}
TM_PER_VARIANT_TARGET=${TM_PER_VARIANT_TARGET:-pic-test-target}
TM_VARIANTS_VAR=${TM_VARIANTS_VAR:-VARIANTS}
TM_VARIANT_ARG=${TM_VARIANT_ARG:-PIC_TARGET_VARIANT}
TM_SUPPORTED=${TM_SUPPORTED:-cd4053 mute relay}
TM_SUBSET=${TM_SUBSET:-mute}
TM_UNSUPPORTED=${TM_UNSUPPORTED:-unknown}
TM_CHECK_SENTINELS=${TM_CHECK_SENTINELS:-1}
TM_FAULT_TARGET=${TM_FAULT_TARGET:-pic-test-fault}
TM_FAULT_VARIANT_ARG=${TM_FAULT_VARIANT_ARG:-PIC_FAULT_VARIANT}
TM_LOCKSTEP_TARGET=${TM_LOCKSTEP_TARGET:-pic-test-lockstep}
TM_LOCKSTEP_VARIANT_ARG=${TM_LOCKSTEP_VARIANT_ARG:-PIC_LOCKSTEP_VARIANT}
TM_IO_TARGET=${TM_IO_TARGET:-pic-test-io}
TM_IO_VARIANT_ARG=${TM_IO_VARIANT_ARG:-PIC_IO_VARIANT}
read -r -a supported <<<"$TM_SUPPORTED"
read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] \
	|| { printf 'FAIL: PROJECT_MAKE must name a Make command\n' >&2; exit 1; }

cat > "$fake_make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL' >> "${FAKE_MAKE_LOG:?}"
printf ' <%s>' "$@" >> "$FAKE_MAKE_LOG"
printf '\n' >> "$FAKE_MAKE_LOG"

target=
marker=
for arg in "$@"; do
	case "$arg" in
		"${FAKE_FAULT_TARGET:?}") target=$arg; marker='FAULT-INJECT PASS' ;;
		"${FAKE_LOCKSTEP_TARGET:?}") target=$arg; marker='LOCK-STEP PASS' ;;
		"${FAKE_IO_TARGET:?}") target=$arg; marker='TARGET-IO PASS' ;;
	esac
done
if [ -n "$target" ] && [ "${FAKE_OMIT_MARKER:-}" != "$target" ]; then
	printf '%s\n' "$marker"
fi
EOF
chmod 750 "$fake_make"

run_matrix() {
	local matrix=$1
	local matrix_arg=()
	if [ "$matrix" != __DEFAULT__ ]; then
		matrix_arg+=("$TM_VARIANTS_VAR=$matrix")
	fi
	: > "$log"
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE "$TM_VARIANTS_VAR"
		FAKE_MAKE_LOG="$log" \
		FAKE_FAULT_TARGET="$TM_FAULT_TARGET" \
		FAKE_LOCKSTEP_TARGET="$TM_LOCKSTEP_TARGET" \
		FAKE_IO_TARGET="$TM_IO_TARGET" \
		"${MAKE_CMD[@]}" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" "${matrix_arg[@]}" "$TM_TARGET"
	)
}

run_target() {
	local omit_marker=${1:-}
	: > "$log"
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE "$TM_VARIANT_ARG"
		FAKE_MAKE_LOG="$log" \
		FAKE_FAULT_TARGET="$TM_FAULT_TARGET" \
		FAKE_LOCKSTEP_TARGET="$TM_LOCKSTEP_TARGET" \
		FAKE_IO_TARGET="$TM_IO_TARGET" \
		FAKE_OMIT_MARKER="$omit_marker" \
		"${MAKE_CMD[@]}" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" "$TM_VARIANT_ARG=$TM_SUBSET" \
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
	mapfile -t calls < "$log"
	[ "${#calls[@]}" -eq "${#expected[@]}" ] \
		|| { printf 'FAIL: %s matrix ran %d variants, expected %d\n' \
			"$label" "${#calls[@]}" "${#expected[@]}" >&2; exit 1; }
	for i in "${!expected[@]}"; do
		[[ "${calls[$i]}" == *"<$TM_VARIANT_ARG=${expected[$i]}>"* \
			&& "${calls[$i]}" == *"<$TM_PER_VARIANT_TARGET>"* ]] \
			|| { printf 'FAIL: %s matrix call %d was wrong: %s\n' \
				"$label" "$i" "${calls[$i]}" >&2; exit 1; }
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

expect_sentinels() {
	local output i
	local targets=("$TM_FAULT_TARGET" "$TM_LOCKSTEP_TARGET" "$TM_IO_TARGET")
	local variant_args=("$TM_FAULT_VARIANT_ARG" "$TM_LOCKSTEP_VARIANT_ARG" "$TM_IO_VARIANT_ARG")
	local markers=('FAULT-INJECT PASS' 'LOCK-STEP PASS' 'TARGET-IO PASS')

	if ! output=$(run_target 2>&1); then
		printf 'FAIL: %s complete target aggregate was rejected: %s\n' "$TM_LABEL" "$output" >&2
		exit 1
	fi
	[[ "$output" == *"PASS (variant $TM_SUBSET)"* ]] \
		|| { printf 'FAIL: %s target aggregate omitted its PASS marker\n' "$TM_LABEL" >&2; exit 1; }
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
		[[ "$output" == *"did not report '${markers[$i]}'"* ]] \
			|| { printf 'FAIL: %s target aggregate reported the wrong missing-marker error: %s\n' \
				"$TM_LABEL" "$output" >&2; exit 1; }
		checks=$((checks + 1))
	done
}

expect_accept default __DEFAULT__ "${supported[@]}"
expect_accept subset "$TM_SUBSET" "$TM_SUBSET"
expect_reject empty "" "$TM_VARIANTS_VAR must not be empty"
expect_reject duplicate "${supported[0]} $TM_SUBSET ${supported[0]}" \
	"$TM_VARIANTS_VAR must not contain duplicate names"
expect_reject unsupported "${supported[0]} $TM_UNSUPPORTED" \
	"$TM_VARIANTS_VAR contains unsupported names"

if [ "$TM_CHECK_SENTINELS" -eq 1 ]; then
	expect_sentinels
fi

printf '%s target-variant matrix validation: %d checks, 0 failures\n' "$TM_LABEL" "$checks"
