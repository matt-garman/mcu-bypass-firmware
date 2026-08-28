#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROGRAM_PARSER="$ROOT/test/parse_xc8_program_space.sh"
CONTEXT_CHECKER="$ROOT/test/check_pic_context_layout.sh"
work=$(mktemp -d "${TMPDIR:-$HOME}/test-xc8-helpers.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_program_pass() {
	local label=$1 expected=$2 transcript=$3 output
	output=$(printf '%s\n' "$transcript" | "$PROGRAM_PARSER") \
		|| fail "$label: rejected a valid program-space record"
	[[ $output == "$expected" ]] \
		|| fail "$label: emitted '$output', expected '$expected'"
	checks=$((checks + 1))
}

expect_program_fail() {
	local label=$1 marker=$2 transcript=$3 output
	if output=$(printf '%s\n' "$transcript" | "$PROGRAM_PARSER" 2>&1); then
		fail "$label: accepted an invalid program-space transcript as '$output'"
	fi
	[[ $output == *"$marker"* ]] \
		|| fail "$label: wrong failure, expected '$marker': $output"
	checks=$((checks + 1))
}

expect_program_pass "canonical record" 42 \
	'Program space used 2Ah (42) of 200h words (8.2%)'
expect_program_pass "spaced leading-zero record" 42 \
	'  Program   space used 02ah ( 00042 ) of 0200h words ( 008.2 % )  '
expect_program_pass "half-way percentage rounded down" 32 \
	'Program space used 20h (32) of 200h words (6.2%)'
expect_program_pass "half-way percentage rounded up" 32 \
	'Program space used 20h (32) of 200h words (6.3%)'
expect_program_fail "half-way percentage outside either XC8 result" \
	"reported percentage" \
	'Program space used 20h (32) of 200h words (6.4%)'
expect_program_fail "missing record" "expected exactly one" 'Memory Summary:'
expect_program_fail "malformed record" "malformed program-space" \
	'Program space used (42)'
expect_program_fail "duplicate record" "expected exactly one" $'Program space used 2Ah (42) of 200h words (8.2%)\nProgram space used 2Ah (42) of 200h words (8.2%)'
expect_program_fail "mixed malformed record" "malformed program-space" $'Program space used 2Ah (42) of 200h words (8.2%)\nProgram space used garbage'
expect_program_fail "hex/decimal disagreement" "hexadecimal and decimal" \
	'Program space used 2Bh (42) of 200h words (8.2%)'
expect_program_fail "zero usage" "usage must be nonzero" \
	'Program space used 0h (0) of 200h words (0.0%)'
expect_program_fail "over-capacity usage" "exceeds the reported capacity" \
	'Program space used 201h (513) of 200h words (100.2%)'
expect_program_fail "percentage disagreement" "reported percentage" \
	'Program space used 2Ah (42) of 200h words (9.9%)'
if output=$("$PROGRAM_PARSER" unexpected 2>&1); then
	fail "program parser accepted an argument: $output"
fi
[[ $output == *"usage:"* ]] || fail "program parser argument failure omitted usage"
checks=$((checks + 1))

asm="$work/image.s"
sym="$work/image.sym"
# The .sym fixtures reproduce real XC8 output rather than a convenient
# shorthand: a global symbol table of "<name> <address> <end> <class> <bank>"
# records, followed by the %segments and %locals sections whose records share
# the file but not the symbol shape. A fixture that carried the address alone
# would let a parser that cannot read an actual .sym pass this suite.
write_valid_context() {
	printf '%s\n' '_ctx_:' ' ds 3' > "$asm"
	printf '%s\n' \
		'_main 188 0 CODE 0' \
		'debounce_init_context@ctx 44 0 BANK0 1' \
		'_ctx_ 5d 0 BANK0 1' \
		'__end_of_main 1FA 0 CODE 0' \
		'%segments' \
		'cstackBANK0 40 63 BANK0 40 1' \
		'%locals' \
		'image.o' \
		'image.s' \
		'329 1FA 0 CODE 0' > "$sym"
}

expect_context_pass() {
	local label=$1 output
	output=$("$CONTEXT_CHECKER" "$asm" "$sym") \
		|| fail "$label: rejected valid context sidecars"
	[[ $output == 5D ]] || fail "$label: emitted '$output', expected 5D"
	checks=$((checks + 1))
}

expect_context_fail() {
	local label=$1 marker=$2 output
	if output=$("$CONTEXT_CHECKER" "$asm" "$sym" 2>&1); then
		fail "$label: accepted invalid context sidecars as '$output'"
	fi
	[[ $output == *"$marker"* ]] \
		|| fail "$label: wrong failure, expected '$marker': $output"
	checks=$((checks + 1))
}

write_valid_context
expect_context_pass "canonical context"

printf '%s\n' '_ctx_:' ' ds 5' > "$asm"
expect_context_fail "wrong allocation size" "invalid context allocation"
write_valid_context
printf '%s\n' '_ctx_:' ' ds 3' '_ctx_:' ' ds 3' > "$asm"
expect_context_fail "duplicate allocation" "expected exactly one"
write_valid_context
printf '_ctx_: ds 3\n' > "$asm"
expect_context_fail "inline malformed allocation" "malformed _ctx_ allocation"
write_valid_context
printf '_ctx_ xyz! 0 BANK0 1\n' > "$sym"
expect_context_fail "malformed symbol" "malformed _ctx_ symbol"
write_valid_context
# The address on its own is not an XC8 symbol record; accepting it would mean
# the parser is reading some other file's shape.
printf '_ctx_ 5d\n' > "$sym"
expect_context_fail "truncated symbol record" "malformed _ctx_ symbol"
write_valid_context
printf '%s\n' '_ctx_ 5d 0 BANK0 1' '_ctx_ 5e 0 BANK0 1' > "$sym"
expect_context_fail "duplicate symbol" "expected exactly one"
write_valid_context
# A _ctx_ the linker resolved into program memory contradicts the `ds 3` data
# allocation, so the address must not be handed to the SRAM harnesses.
printf '_ctx_ 5d 0 CODE 0\n' > "$sym"
expect_context_fail "symbol placed in program memory" "program memory"
write_valid_context
# %segments and %locals records are not symbols; a psect that happens to be
# named _ctx_ must neither satisfy nor corrupt the lookup.
printf '%s\n' '_main 188 0 CODE 0' '%segments' '_ctx_ 40 63 BANK0 40 1' > "$sym"
expect_context_fail "symbol only in the segment table" "expected exactly one"
write_valid_context
printf '%s\n' '_ctx_ 5d 0 BANK0 1' '%segments' '_ctx_ 40 63 BANK0 40 1' > "$sym"
expect_context_pass "segment record shadowing the symbol"
write_valid_context
: > "$sym"
expect_context_fail "empty symbol file" "missing, empty, symlinked"
write_valid_context
mv "$sym" "$work/real.sym"
ln -s "$work/real.sym" "$sym"
expect_context_fail "symlink symbol file" "missing, empty, symlinked"
rm -f "$sym"
write_valid_context
rm -f "$asm"
expect_context_fail "missing assembly" "missing, empty, symlinked"
write_valid_context
if output=$("$CONTEXT_CHECKER" "$asm" 2>&1); then
	fail "context checker accepted an incomplete request: $output"
fi
[[ $output == *"usage:"* ]] || fail "context checker request failure omitted usage"
checks=$((checks + 1))

printf 'XC8 strict-helper validation: %d checks, 0 failures\n' "$checks"
