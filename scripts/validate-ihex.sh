#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
	printf 'usage: %s <image.hex>\n' "$0" >&2
	exit 2
fi

image=$1
if [ ! -f "$image" ] || [ -L "$image" ] || [ ! -s "$image" ]; then
	printf 'ERROR: Intel HEX image is not a nonempty regular file: %s\n' "$image" >&2
	exit 1
fi

if ! LC_ALL=C awk '
	function nibble(c) { return index("0123456789ABCDEF", c) - 1 }
	function byte_at(s, p) { return nibble(substr(s, p, 1)) * 16 + nibble(substr(s, p + 1, 1)) }
	BEGIN { valid = 1 }
	{
		sub(/\r$/, "")
		line = toupper($0)
		if (eof_count || line !~ /^:[[:xdigit:]]+$/) { valid = 0; next }
		record = substr(line, 2)
		record_len = length(record)
		if (record_len < 10 || record_len % 2) { valid = 0; next }
		byte_count = byte_at(record, 1)
		if (record_len != 10 + byte_count * 2) { valid = 0; next }
		sum = 0
		for (i = 1; i <= record_len; i += 2) sum += byte_at(record, i)
		if (sum % 256 != 0) { valid = 0; next }
		address = substr(record, 3, 4)
		record_type = substr(record, 7, 2)
		if (record_type == "00") {
			if (byte_count == 0) { valid = 0; next }
			data_bytes += byte_count
		} else if (record_type == "01") {
			if (record != "00000001FF") { valid = 0; next }
			eof_count++
		} else if (record_type == "02" || record_type == "04") {
			if (byte_count != 2 || address != "0000") { valid = 0; next }
		} else if (record_type == "03" || record_type == "05") {
			if (byte_count != 4 || address != "0000") { valid = 0; next }
		} else {
			valid = 0
		}
	}
	END { exit !(valid && NR > 0 && data_bytes > 0 && eof_count == 1) }
' "$image"; then
	printf 'ERROR: invalid Intel HEX image: %s\n' "$image" >&2
	exit 1
fi
