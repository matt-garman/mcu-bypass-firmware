#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic-target-result-records.XXXXXX")
trap 'rm -rf "$work"' EXIT
. "$ROOT/test/pic/pic12f675_target_counts.sh"

cxx=${PIC_SOAK_CXX:-c++}
command -v "$cxx" >/dev/null 2>&1 \
	|| { printf 'FAIL: C++ compiler not found: %s\n' "$cxx" >&2; exit 1; }

records=()
expected=()
variants=()
while read -r variant fault_checks lockstep_checks io_checks; do
	variants+=("$variant")
	bin="$work/records-$variant"
	"$cxx" -std=c++17 -Wall -Wextra -Werror -I"$ROOT/test" \
		"-DPIC_TARGET_RESULT_VARIANT=\"$variant\"" \
		"-DPIC_TARGET_RESULT_FAULT_CHECKS=${fault_checks}u" \
		"-DPIC_TARGET_RESULT_LOCKSTEP_CHECKS=${lockstep_checks}u" \
		"-DPIC_TARGET_RESULT_IO_CHECKS=${io_checks}u" \
		"$ROOT/test/pic/test_target_result_records.cc" -o "$bin"
	mapfile -t variant_records < <("$bin")
	records+=("${variant_records[@]}")
	expected+=(
		"PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=$variant status=pass checks=$fault_checks failures=0"
		"PIC_TARGET_RESULT format=1 device=pic12f675 lane=lockstep variant=$variant status=pass checks=$lockstep_checks failures=0"
		"PIC_TARGET_RESULT format=1 device=pic12f675 lane=io variant=$variant status=pass checks=$io_checks failures=0"
	)
done < <(pic12f675_target_count_table)

canonical_variants=(cd4053_simple cd4053_with_mute tq2_l2_5v_relay)
[ "${variants[*]}" = "${canonical_variants[*]}" ] \
	|| { printf 'FAIL: canonical count table variants were: %s\nexpected: %s\n' \
		"${variants[*]}" "${canonical_variants[*]}" >&2; exit 1; }

[ "${#records[@]}" -eq "${#expected[@]}" ] \
	|| { printf 'FAIL: record producers emitted %d lines, expected %d\n' \
		"${#records[@]}" "${#expected[@]}" >&2; exit 1; }
for i in "${!expected[@]}"; do
	[ "${records[$i]}" = "${expected[$i]}" ] \
		|| { printf 'FAIL: result record %d was:\n%s\nexpected:\n%s\n' \
			"$i" "${records[$i]}" "${expected[$i]}" >&2; exit 1; }
done

python3 "$ROOT/test/pic/check_target_result_producers.py"

printf 'PIC target result producer validation: %d checks, 0 failures\n' \
	"$((${#expected[@]} + 9))"
