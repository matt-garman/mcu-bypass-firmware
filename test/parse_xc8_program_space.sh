#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C

fail() {
	printf 'XC8 program-space parser: %s\n' "$*" >&2
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

[[ $# -eq 0 ]] || fail "usage: $0 < xc8-transcript"

record_re='^[[:space:]]*Program[[:space:]]+space[[:space:]]+used[[:space:]]+([0-9A-Fa-f]+)h[[:space:]]+\([[:space:]]*([0-9]+)[[:space:]]*\)[[:space:]]+of[[:space:]]+([0-9A-Fa-f]+)h[[:space:]]+words[[:space:]]+\([[:space:]]*([0-9]+[.][0-9])[[:space:]]*%[[:space:]]*\)[[:space:]]*$'
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
	elif [[ $line =~ Program[[:space:]]+space ]]; then
		malformed_count=$((malformed_count + 1))
	fi
done

[[ $malformed_count -eq 0 ]] \
	|| fail "transcript contains $malformed_count malformed program-space record(s)"
[[ $record_count -eq 1 ]] \
	|| fail "expected exactly one program-space record, found $record_count"

normalize_hex "$capacity_hex"
capacity_hex=$REPLY
[[ ${#capacity_hex} -le 8 ]] || fail "program-space capacity is out of range"
capacity=$((16#$capacity_hex))
[[ $capacity -gt 0 ]] || fail "program-space capacity must be nonzero"

normalize_decimal "$used_decimal"
used_decimal=$REPLY
capacity_decimal=$capacity
if [[ ${#used_decimal} -gt ${#capacity_decimal} \
		|| (${#used_decimal} -eq ${#capacity_decimal} \
			&& x$used_decimal > x$capacity_decimal) ]]; then
	fail "program-space usage exceeds the reported capacity"
fi
[[ $used_decimal != 0 ]] || fail "program-space usage must be nonzero"

normalize_hex "$used_hex"
used_hex=$REPLY
[[ ${#used_hex} -le ${#capacity_hex} ]] \
	|| fail "program-space hexadecimal usage exceeds the reported capacity"
used_from_hex=$((16#$used_hex))
[[ $used_decimal == "$used_from_hex" ]] \
	|| fail "used hexadecimal and decimal counts disagree"

scaled_percent=$((used_from_hex * 1000))
expected_tenths=$((scaled_percent / capacity))
percent_remainder=$((scaled_percent % capacity))
if [[ $percent_remainder -gt $((capacity / 2)) ]]; then
	expected_tenths=$((expected_tenths + 1))
fi
expected_percent="$((expected_tenths / 10)).$((expected_tenths % 10))"
alternate_percent=
if [[ $((percent_remainder * 2)) -eq $capacity ]]; then
	alternate_tenths=$((expected_tenths + 1))
	alternate_percent="$((alternate_tenths / 10)).$((alternate_tenths % 10))"
fi
percent_whole=${reported_percent%.*}
percent_fraction=${reported_percent#*.}
normalize_decimal "$percent_whole"
reported_percent="$REPLY.$percent_fraction"
[[ $reported_percent == "$expected_percent" \
		|| (-n $alternate_percent && $reported_percent == "$alternate_percent") ]] \
	|| fail "reported percentage $reported_percent% disagrees with $used_decimal/$capacity words"

printf '%s\n' "$used_decimal"
