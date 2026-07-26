#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-target-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake_make="$work/fake-make"
log="$work/make.log"
checks=0
supported=(cd4053-simple cd4053-mute tq2-relay)
MAKE_CMD=${PROJECT_MAKE:-make}

cat > "$fake_make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL' >> "${FAKE_MAKE_LOG:?}"
printf ' <%s>' "$@" >> "$FAKE_MAKE_LOG"
printf '\n' >> "$FAKE_MAKE_LOG"
EOF
chmod 750 "$fake_make"

run_matrix() {
	local matrix=$1
	local matrix_arg=()
	if [ "$matrix" != __DEFAULT__ ]; then
		matrix_arg+=("PIC_VARIANTS_ALL=$matrix")
	fi
	: > "$log"
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE PIC_VARIANTS_ALL PIC_TARGET_VARIANTS_SUPPORTED
		FAKE_MAKE_LOG="$log" "$MAKE_CMD" --no-print-directory -C "$ROOT" \
			_MAKE_SERIAL_LOCK_HELD=1 MAKE="$fake_make" \
			"${matrix_arg[@]}" test-target-variants
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
		[[ "${calls[$i]}" == *"<PIC_VARIANT=${expected[$i]}>"* \
			&& "${calls[$i]}" == *"<test-target-gpsim>"* ]] \
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

expect_accept default __DEFAULT__ "${supported[@]}"
expect_accept subset cd4053-mute cd4053-mute
expect_reject empty "" "PIC_VARIANTS_ALL must not be empty"
expect_reject duplicate "cd4053-simple cd4053-mute cd4053-simple" \
	"PIC_VARIANTS_ALL must not contain duplicate names"
expect_reject unsupported "cd4053-simple unknown" "PIC_VARIANTS_ALL contains unsupported names"

printf 'target-variant matrix validation: %d checks, 0 failures\n' "$checks"
