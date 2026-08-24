#!/usr/bin/env bash
# Validate GCC -fstack-usage reports without numeric precision loss.
set -euo pipefail

die() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ "$#" -ge 2 ] \
	|| die "usage: $0 <maximum-frame-bytes> <report.su> [report.su ...]"

max=$1
shift
[[ "$max" =~ ^[0-9]+$ && "$max" =~ [1-9] ]] \
	|| die "stack-frame limit must be a positive decimal integer"

for report in "$@"; do
	[ -f "$report" ] && [ ! -L "$report" ] && [ -s "$report" ] \
		|| die "stack-usage report is missing, empty, or not a regular file: $report"
done

printf 'Per-function stack frames:\n'
cat -- "$@" || die "could not read stack-usage reports"

awk -F'\t' -v max="$max" '
	function decimal_gt(a, b) {
		sub(/^0+/, "", a); sub(/^0+/, "", b)
		if (a == "") a = "0"; if (b == "") b = "0"
		if (length(a) != length(b)) return length(a) > length(b)
		return ("x" a) > ("x" b)
	}
	BEGIN { bad = 0; records = 0 }
	NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 != "static" {
		printf "invalid stack-usage record: %s\n", $0 > "/dev/stderr"; bad = 1; next
	}
	{ records++; if (decimal_gt($2, max)) {
		printf "frame exceeds %s B: %s\n", max, $0 > "/dev/stderr"; bad = 1
	} }
	END {
		if (records == 0) {
			print "no stack-usage records" > "/dev/stderr"; bad = 1
		}
		exit bad
	}' "$@" || die "invalid or oversized stack frame evidence"
