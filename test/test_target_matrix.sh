#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-target-matrix.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake_make="$work/fake-make"
log="$work/make.log"
checks=0
supported=(cd4053 mute relay)
read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] \
	|| { printf 'FAIL: PROJECT_MAKE must name a Make command\n' >&2; exit 1; }

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
		matrix_arg+=("VARIANTS=$matrix")
	fi
	: > "$log"
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE VARIANTS PIC_TARGET_VARIANTS_SUPPORTED
		FAKE_MAKE_LOG="$log" "${MAKE_CMD[@]}" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" "${matrix_arg[@]}" pic-test-target-variants
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
		[[ "${calls[$i]}" == *"<PIC_TARGET_VARIANT=${expected[$i]}>"* \
			&& "${calls[$i]}" == *"<pic-test-target>"* ]] \
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
expect_accept subset mute mute
expect_reject empty "" "VARIANTS must not be empty"
expect_reject duplicate "cd4053 mute cd4053" "VARIANTS must not contain duplicate names"
expect_reject unsupported "cd4053 unknown" "VARIANTS contains unsupported names"

printf 'PIC target-variant matrix validation: %d checks, 0 failures\n' "$checks"
