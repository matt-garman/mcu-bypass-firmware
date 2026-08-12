#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic-target-result-records.XXXXXX")
trap 'rm -rf "$work"' EXIT

cxx=${PIC_SOAK_CXX:-c++}
command -v "$cxx" >/dev/null 2>&1 \
	|| { printf 'FAIL: C++ compiler not found: %s\n' "$cxx" >&2; exit 1; }

"$cxx" -std=c++17 -Wall -Wextra -Werror -I"$ROOT/test" \
	"$ROOT/test/pic/test_target_result_records.cc" -o "$work/records"

mapfile -t records < <("$work/records")
expected=(
	'PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=pass checks=37 failures=0'
	'PIC_TARGET_RESULT format=1 device=pic12f675 lane=lockstep variant=tq2_l2_5v_relay status=pass checks=3005 failures=0'
	'PIC_TARGET_RESULT format=1 device=pic12f675 lane=io variant=tq2_l2_5v_relay status=pass checks=36 failures=0'
)

[ "${#records[@]}" -eq "${#expected[@]}" ] \
	|| { printf 'FAIL: record producers emitted %d lines, expected %d\n' \
		"${#records[@]}" "${#expected[@]}" >&2; exit 1; }
for i in "${!expected[@]}"; do
	[ "${records[$i]}" = "${expected[$i]}" ] \
		|| { printf 'FAIL: result record %d was:\n%s\nexpected:\n%s\n' \
			"$i" "${records[$i]}" "${expected[$i]}" >&2; exit 1; }
done

while IFS='|' read -r source lane; do
	[ "$(grep -cF "pic_target_result(\"$lane\"" "$ROOT/$source")" -eq 1 ] \
		|| { printf 'FAIL: %s does not emit exactly one %s result\n' \
			"$source" "$lane" >&2; exit 1; }
done <<'EOF'
test/pic/test_fault_pic_core.h|fault
test/pic/test_lockstep_pic_core.h|lockstep
test/pic/test_io_pic_core.h|io
EOF

printf 'PIC target result producer validation: 6 checks, 0 failures\n'
