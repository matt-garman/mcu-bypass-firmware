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

# XC8 opens the .sym with its global symbol table -- one record per line,
# "<name> <address> <end> <class> <bank>" with hexadecimal addresses -- and
# then switches to unrelated record shapes at the first %-directive
# (%segments, then %locals). Only the global table resolves _ctx_ to the SRAM
# address the gpsim harnesses poke, so the scan stops at that boundary instead
# of matching a like-named psect or local-symbol record further down. Across the
# pinned XC8/DFP and all three supported PIC families, the reviewed _ctx_ class
# is BANK0. Accept that exact data-memory class rather than guessing that every
# syntactically valid class except CODE is SRAM.
address=$(
	awk '
		BEGIN { globals = 1 }
		/^%/ { globals = 0 }
		globals != 1 { next }
		$1 == "_ctx_" {
			records++
			if (NF != 5 || $2 !~ /^[0-9A-Fa-f]+$/ || $3 !~ /^[0-9A-Fa-f]+$/ \
					|| $4 !~ /^[A-Z][0-9A-Z_]*$/ || $5 !~ /^[0-9]+$/) {
				malformed++
				next
			}
			if ($4 != "BANK0") { wrong_class++; symbol_class = $4; next }
			address = toupper($2)
		}
		END {
			if (malformed != 0) {
				printf "malformed _ctx_ symbol record(s): %d\n", malformed > "/dev/stderr"
				exit 2
			}
			if (wrong_class != 0) {
				printf "_ctx_ symbol class %s is not the reviewed BANK0 data-memory class\n", symbol_class > "/dev/stderr"
				exit 3
			}
			if (records != 1) {
				printf "expected exactly one _ctx_ symbol, found %d\n", records > "/dev/stderr"
				exit 4
			}
			print address
		}
	' "$sym"
) || fail "invalid context symbol in $sym"
[[ -n $address ]] || fail "context symbol parser emitted an empty address"

printf '%s\n' "$address"
