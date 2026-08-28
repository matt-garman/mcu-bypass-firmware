#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C

fail() {
	printf 'PIC context-layout checker: %s\n' "$*" >&2
	exit 1
}

[[ $# -eq 2 ]] || fail "usage: $0 <generated.s> <generated.sym>"
asm=$1
sym=$2

for input in "$asm" "$sym"; do
	[[ -f $input && ! -L $input && -s $input ]] \
		|| fail "input is missing, empty, symlinked, or not a regular file: $input"
done

allocation=$(
	awk '
		/^[[:space:]]*_ctx_:[[:space:]]*$/ {
			labels++
			if (getline <= 0) { malformed++; next }
			if ($0 !~ /^[[:space:]]*ds[[:space:]]+3[[:space:]]*$/) malformed++
		}
		/^[[:space:]]*_ctx_:/ && $0 !~ /^[[:space:]]*_ctx_:[[:space:]]*$/ {
			malformed++
		}
		END {
			if (malformed != 0) {
				printf "malformed _ctx_ allocation record(s): %d\n", malformed > "/dev/stderr"
				exit 2
			}
			if (labels != 1) {
				printf "expected exactly one _ctx_: ds 3 allocation, found %d\n", labels > "/dev/stderr"
				exit 3
			}
			print 3
		}
	' "$asm"
) || fail "invalid context allocation in $asm"
[[ $allocation == 3 ]] || fail "internal allocation parser error for $asm"

address=$(
	awk '
		$1 == "_ctx_" {
			records++
			if (NF != 2 || $2 !~ /^[0-9A-Fa-f]+$/) malformed++
			else address = toupper($2)
		}
		END {
			if (malformed != 0) {
				printf "malformed _ctx_ symbol record(s): %d\n", malformed > "/dev/stderr"
				exit 2
			}
			if (records != 1) {
				printf "expected exactly one _ctx_ symbol, found %d\n", records > "/dev/stderr"
				exit 3
			}
			print address
		}
	' "$sym"
) || fail "invalid context symbol in $sym"
[[ -n $address ]] || fail "context symbol parser emitted an empty address"

printf '%s\n' "$address"
