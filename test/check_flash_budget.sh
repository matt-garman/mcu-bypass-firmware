#!/usr/bin/env bash
# Fail unless every supplied firmware ELF has one valid, in-budget size report.
set -euo pipefail

die() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -lt 6 ]; then
	printf 'usage: %s <size-command> <mcu> <flash-bytes> <budget-percent> <expected-count> <elf> [elf ...]\n' "$0" >&2
	exit 2
fi

size_string=$1
mcu=$2
flash_bytes=$3
budget_percent=$4
expected_count=$5
shift 5
elfs=("$@")
read -r -a size_command <<<"$size_string"
[ "${#size_command[@]}" -gt 0 ] || die "size command is empty"
[ -n "$mcu" ] || die "MCU name is empty"

normalize_decimal() {
	local value=$1
	while [ "${#value}" -gt 1 ] && [[ "$value" == 0* ]]; do value=${value#0}; done
	printf '%s' "$value"
}

decimal_gt() {
	local left right
	left=$(normalize_decimal "$1")
	right=$(normalize_decimal "$2")
	if [ "${#left}" -ne "${#right}" ]; then [ "${#left}" -gt "${#right}" ]; return; fi
	[[ "x$left" > "x$right" ]]
}

is_uint32() {
	local value normalized
	value=$1
	[[ "$value" =~ ^[0-9]+$ ]] || return 1
	normalized=$(normalize_decimal "$value")
	[ "$normalized" != 0 ] || return 1
	! decimal_gt "$normalized" 4294967295
}

is_uint32 "$flash_bytes" || die "flash byte count must be in [1, 4294967295]"
is_uint32 "$expected_count" || die "expected image count must be in [1, 4294967295]"
expected_count=$(normalize_decimal "$expected_count")
[ "${#elfs[@]}" -eq "$expected_count" ] \
	|| die "expected $expected_count firmware images, received ${#elfs[@]}"
[[ "$budget_percent" =~ ^[0-9]+$ ]] \
	|| die "flash budget percentage must be an integer in [1, 100]"
budget_percent=$(normalize_decimal "$budget_percent")
[ "$budget_percent" != 0 ] && ! decimal_gt "$budget_percent" 100 \
	|| die "flash budget percentage must be an integer in [1, 100]"
flash_bytes=$(normalize_decimal "$flash_bytes")
limit=$((flash_bytes * budget_percent / 100))
[ "$limit" -gt 0 ] || die "flash budget resolves to zero bytes"

printf '=== flash-utilization budget (%s: %s%% of %s B = %s B) ===\n' \
	"$mcu" "$budget_percent" "$flash_bytes" "$limit"

measured=0
for elf in "${elfs[@]}"; do
	[ -f "$elf" ] && [ ! -L "$elf" ] && [ -s "$elf" ] \
		|| die "firmware ELF is missing, empty, or not a regular file: $elf"
	if ! size_output=$(LC_ALL=C "${size_command[@]}" --mcu="$mcu" -C "$elf" 2>&1); then
		printf '%s\n' "$size_output" >&2
		die "size command failed for $elf"
	fi
	program_lines=0
	used=
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}
		if [[ "$line" == Program:* ]]; then
			program_lines=$((program_lines + 1))
			[[ "$line" =~ ^Program:[[:space:]]+([0-9]+)[[:space:]]+bytes[[:space:]]+\([0-9]+([.][0-9]+)?%[[:space:]]+Full\)$ ]] \
				|| die "malformed Program size for $elf: $line"
			used=${BASH_REMATCH[1]}
		fi
	done <<<"$size_output"
	[ "$program_lines" -eq 1 ] || die "expected one Program size for $elf, found $program_lines"
	used=$(normalize_decimal "$used")
	[ "$used" != 0 ] || die "Program size must be greater than zero for $elf"
	if decimal_gt "$used" "$limit"; then
		pct=$(LC_ALL=C awk -v u="$used" -v t="$flash_bytes" 'BEGIN {printf "%.1f", u*100/t}')
		die "$elf uses $used B ($pct%) -- exceeds $limit B ($budget_percent%)"
	fi
	pct=$(LC_ALL=C awk -v u="$used" -v t="$flash_bytes" 'BEGIN {printf "%.1f", u*100/t}')
	printf 'OK:   %s uses %s B (%s%%) of %s B\n' "$elf" "$used" "$pct" "$flash_bytes"
	measured=$((measured + 1))
done

[ "$measured" -eq "$expected_count" ] || die "measured $measured/$expected_count firmware images"
printf 'OK: measured all %d firmware images; each is within the %s B limit.\n' \
	"$measured" "$limit"
