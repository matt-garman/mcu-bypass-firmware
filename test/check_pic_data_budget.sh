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
LC_ALL=C

fail() {
	printf 'PIC12F675 data-budget gate: %s\n' "$*" >&2
	exit 1
}

normalize_decimal() {
	local value=$1
	while [[ ${#value} -gt 1 && $value == 0* ]]; do
		value=${value#0}
	done
	REPLY=$value
}

normalize_hex() {
	local value=${1^^}
	while [[ ${#value} -gt 1 && $value == 0* ]]; do
		value=${value#0}
	done
	REPLY=$value
}

[[ $# -eq 2 ]] || fail "usage: $0 <variant> <policy-limit-bytes>"
variant=$1
limit=$2
[[ $variant =~ ^[a-z0-9_]+$ ]] || fail "invalid variant '$variant'"
[[ $limit =~ ^[0-9]+$ ]] || fail "policy limit must be a positive decimal integer no greater than 64"
normalize_decimal "$limit"
limit=$REPLY
if [[ $limit == 0 || ${#limit} -gt 2 \
		|| (${#limit} -eq 2 && $limit > 64) ]]; then
	fail "policy limit must be a positive decimal integer no greater than 64"
fi

record_re='^[[:space:]]*Data[[:space:]]+space[[:space:]]+used[[:space:]]+([0-9A-Fa-f]+)h[[:space:]]+\([[:space:]]*([0-9]+)[[:space:]]*\)[[:space:]]+of[[:space:]]+([0-9A-Fa-f]+)h[[:space:]]+bytes[[:space:]]+\([[:space:]]*([0-9]+[.][0-9])[[:space:]]*%[[:space:]]*\)[[:space:]]*$'
record_count=0
malformed_count=0
used_hex=
used_decimal=
capacity_hex=
reported_percent=

while IFS= read -r line || [[ -n $line ]]; do
	if [[ $line =~ $record_re ]]; then
		record_count=$((record_count + 1))
		used_hex=${BASH_REMATCH[1]}
		used_decimal=${BASH_REMATCH[2]}
		capacity_hex=${BASH_REMATCH[3]}
		reported_percent=${BASH_REMATCH[4]}
	elif [[ $line =~ Data[[:space:]]+space[[:space:]]+used ]]; then
		malformed_count=$((malformed_count + 1))
	fi
done

[[ $malformed_count -eq 0 ]] \
	|| fail "transcript contains $malformed_count malformed data-space record(s)"
[[ $record_count -eq 1 ]] \
	|| fail "expected exactly one data-space record, found $record_count"

normalize_hex "$capacity_hex"
capacity_hex=$REPLY
[[ ${#capacity_hex} -le 2 ]] || fail "record capacity must be 40h (64) bytes"
capacity_from_hex=$((16#$capacity_hex))
[[ $capacity_from_hex -eq 64 ]] || fail "record capacity must be 40h (64) bytes"

normalize_hex "$used_hex"
used_hex=$REPLY
[[ ${#used_hex} -le 2 ]] || fail "data-space usage exceeds the 64-byte device capacity"
used_from_hex=$((16#$used_hex))
normalize_decimal "$used_decimal"
used_decimal=$REPLY
[[ $used_decimal == "$used_from_hex" ]] \
	|| fail "used hexadecimal and decimal counts disagree"
[[ $used_from_hex -gt 0 ]] || fail "data-space usage must be nonzero"
[[ $used_from_hex -le 64 ]] || fail "data-space usage exceeds the 64-byte device capacity"
scaled_percent=$((used_from_hex * 1000))
expected_tenths=$((scaled_percent / 64))
percent_remainder=$((scaled_percent % 64))
if [[ $percent_remainder -gt 32 ]]; then
	expected_tenths=$((expected_tenths + 1))
fi
expected_percent="$((expected_tenths / 10)).$((expected_tenths % 10))"
alternate_percent=
if [[ $percent_remainder -eq 32 ]]; then
	alternate_tenths=$((expected_tenths + 1))
	alternate_percent="$((alternate_tenths / 10)).$((alternate_tenths % 10))"
fi
percent_whole=${reported_percent%.*}
percent_fraction=${reported_percent#*.}
normalize_decimal "$percent_whole"
percent_whole=$REPLY
[[ ${#percent_whole} -le 3 ]] \
	|| fail "reported percentage is out of range: $reported_percent%"
reported_percent="$percent_whole.$percent_fraction"
[[ $reported_percent == "$expected_percent" \
		|| (-n $alternate_percent && $reported_percent == "$alternate_percent") ]] \
	|| fail "reported percentage $reported_percent% disagrees with $used_from_hex/64 bytes ($expected_percent%${alternate_percent:+ or $alternate_percent%})"
[[ $used_from_hex -le $limit ]] \
	|| fail "variant $variant uses $used_from_hex bytes, exceeding the $limit-byte policy limit"

printf 'PIC12F675_DATA_BUDGET PASS variant=%s used=%d limit=%s capacity=64\n' \
	"$variant" "$used_from_hex" "$limit"
