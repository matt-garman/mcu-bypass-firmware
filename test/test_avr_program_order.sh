#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# Every AVR `*-program` goal is one ORDERED transaction, and its software half
# completes before its hardware half begins.
#
# THE DEFECT CLASS. `attiny13a-program: attiny13a-fuses attiny13a-flash` reads
# like "fuses, then flash", and under the repo's forced -j1 that is what Make
# ran -- fuse write first, with the firmware image only a prerequisite of the
# LATER flash goal. A compile, link, size or Intel-HEX failure therefore landed
# after the device's clock, watchdog and BOD fuses had already been rewritten,
# leaving a part configured for firmware that does not exist. The window is not
# hypothetical on a fresh chip: the fuse write is what moves it off its factory
# clock, so the failed state is a device that no longer runs at the speed its
# old firmware assumed.
#
# WHAT IS CHECKED, per part (ATtiny13A, ATtiny45, ATtiny85, ATtiny202):
#
#   ORDER        the image is compiled and converted to a validated HEX before
#                the first avrdude invocation, the fuse write precedes the
#                flash write, and there is exactly ONE of each. A second fuse
#                transaction or a flash-before-fuse ordering fails here.
#   NO-BUILD     a failed compile invokes avrdude ZERO times.
#   NO-HEX       an image that fails Intel HEX validation invokes avrdude ZERO
#                times -- the objcopy output is rejected, not programmed.
#   NO-IMAGE     a build that legitimately produces nothing (ATtiny202 with no
#                device pack, which SKIPs) refuses instead of writing fuses.
#   NO-TOOL      a named-but-unusable programmer refuses before any hardware
#                action, on the same -x rule the HEX validator uses.
#
# HERMETIC. Fake cc/objcopy/readelf/size/avrdude write into one shared event
# log, so ORDER is read off the real recipe's real execution order rather than
# from `make -n` text. Build output goes to scratch directories; the tree's own
# build_avr_classic/ and build_avr_xt/ are never touched.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-avr-program.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
classic_build="$work/classic"
xt_build="$work/xt"
dfp="$work/dfp"
log="$work/events.log"
checks=0
failures=0

unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
unset FAKE_CC_MODE FAKE_OBJCOPY_MODE
unset AVR_BUILD_DIR AVR_FW FW_BASE XT_BUILD_DIR XT_DFP AVRDUDE
# scripts/ci-local.sh exports STRICT_TOOLS=1; the NO-IMAGE case needs the
# ordinary skip policy, and pins what it needs explicitly.
unset STRICT_TOOLS

mkdir -p "$tools" "$classic_build" "$xt_build" \
	"$dfp/gcc/dev/attiny202/device-specs" "$dfp/include/avr"
: > "$dfp/gcc/dev/attiny202/device-specs/specs-attiny202"
: > "$dfp/include/avr/iotn202.h"

fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

cat > "$tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake avr-gcc 1\n'; exit 0; fi
out=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
printf 'CC %s\n' "$out" >> "$FAKE_EVENT_LOG"
case "${FAKE_CC_MODE:-pass}" in
	fail) printf 'partial ELF\n' > "$out"; exit 1 ;;
	*) printf 'fresh ELF\n' > "$out" ;;
esac
EOF

cat > "$tools/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '  Machine:                           Atmel AVR 8-bit microcontroller\n'
printf '  Flags:                             0x19, avr:25, link-relax\n'
printf '  Flags:                             0x0, avr:103\n'
EOF

cat > "$tools/size" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'AVR Memory Usage\nDevice: Unknown\n\nProgram: 100 bytes\nData: 8 bytes\n'
EOF

cat > "$tools/objcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do out=$arg; done
printf 'OBJCOPY %s\n' "$out" >> "$FAKE_EVENT_LOG"
case "${FAKE_OBJCOPY_MODE:-pass}" in
	invalid) printf 'not Intel HEX\n' > "$out" ;;
	*) printf ':0100000001FE\n:00000001FF\n' > "$out" ;;
esac
EOF

# Classifies itself from its own argv, so a recipe cannot log a fuse write and
# then perform a flash one. `:m` is the fuse memory form, `flash:w:...:i` the
# image form -- the same two shapes test_fuse_injection_contract.py keys on.
cat > "$tools/avrdude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
kind=OTHER
case "$*" in
	*flash:w:*:i*) kind=FLASH ;;
	*:w:*:m*)      kind=FUSE ;;
	*:r:*)         kind=READ ;;
esac
printf 'AVRDUDE %s %s\n' "$kind" "$*" >> "$FAKE_EVENT_LOG"
EOF
chmod 750 "$tools"/*

run_program() {
	local goal=$1; shift
	FAKE_EVENT_LOG="$log" \
	make --no-print-directory -C "$ROOT" "$goal" \
		AVR_BUILD_DIR="$classic_build" XT_BUILD_DIR="$xt_build" \
		XT_DFP="${TEST_DFP-$dfp}" \
		CC="$tools/cc" READELF="$tools/readelf" SIZE="$tools/size" \
		OBJCOPY="$tools/objcopy" AVRDUDE="${TEST_AVRDUDE-$tools/avrdude}" \
		"$@"
}

first_index() { grep -n -E "$1" "$log" | head -1 | cut -d: -f1; }
count_of()    { grep -c -E "$1" "$log" || true; }

# ---- ORDER: one build, then exactly one fuse write, then one flash write -----
for part in attiny13a attiny45 attiny85 attiny202; do
	: > "$log"
	if ! run_program "$part-program" >/dev/null 2>&1; then
		fail "$part-program did not complete with fake tools"
		checks=$((checks + 1))
		continue
	fi

	cc_at=$(first_index '^CC ')
	hex_at=$(first_index '^OBJCOPY ')
	fuse_at=$(first_index '^AVRDUDE FUSE ')
	flash_at=$(first_index '^AVRDUDE FLASH ')
	fuses=$(count_of '^AVRDUDE FUSE ')
	flashes=$(count_of '^AVRDUDE FLASH ')
	others=$(count_of '^AVRDUDE (OTHER|READ) ')

	if [ -z "$cc_at" ] || [ -z "$hex_at" ] || [ -z "$fuse_at" ] || [ -z "$flash_at" ]; then
		fail "$part-program did not record a build, a fuse write and a flash write"
	elif [ "$cc_at" -ge "$fuse_at" ] || [ "$hex_at" -ge "$fuse_at" ]; then
		fail "$part-program wrote fuses before the image was built and converted"
	elif [ "$fuse_at" -ge "$flash_at" ]; then
		fail "$part-program did not write fuses before flash"
	elif [ "$fuses" -ne 1 ] || [ "$flashes" -ne 1 ] || [ "$others" -ne 0 ]; then
		fail "$part-program ran $fuses fuse, $flashes flash and $others other programmer commands (want 1/1/0)"
	fi
	checks=$((checks + 1))

	# The flash write must name the image the build actually produced.
	if ! grep -q -E "^AVRDUDE FLASH .*flash:w:.*$part.*\.hex:i" "$log"; then
		fail "$part-program flashed an image that is not this part's build product"
	fi
	checks=$((checks + 1))
done

# ---- NO-BUILD: a failed compile reaches no programmer -----------------------
for part in attiny13a attiny85 attiny202; do
	: > "$log"
	rm -rf "$classic_build" "$xt_build"; mkdir -p "$classic_build" "$xt_build"
	if FAKE_CC_MODE=fail run_program "$part-program" >/dev/null 2>&1; then
		fail "$part-program succeeded with a failing compiler"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program invoked the programmer after a failed compile"
	fi
	checks=$((checks + 1))
done

# ---- NO-HEX: an image rejected by the HEX validator reaches no programmer ----
for part in attiny13a attiny85 attiny202; do
	: > "$log"
	rm -rf "$classic_build" "$xt_build"; mkdir -p "$classic_build" "$xt_build"
	if FAKE_OBJCOPY_MODE=invalid run_program "$part-program" >/dev/null 2>&1; then
		fail "$part-program succeeded with an image the HEX validator rejects"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program invoked the programmer after failed HEX validation"
	fi
	checks=$((checks + 1))
done

# ---- NO-IMAGE: a build that skips must refuse, not write fuses ---------------
# The ATtiny202 build SKIPs (exit 0, no image) when the device pack is absent,
# which is exactly the shape that used to reach the fuse write with nothing to
# flash afterwards.
: > "$log"
rm -rf "$xt_build"; mkdir -p "$xt_build"
if TEST_DFP="$work/absent-dfp" run_program attiny202-program >/dev/null 2>&1; then
	fail "attiny202-program succeeded with no device pack and no image"
fi
if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
	fail "attiny202-program invoked the programmer with no image to flash"
fi
checks=$((checks + 1))

# ---- NO-TOOL: a named-but-unusable programmer refuses before any action ------
printf '#!/bin/sh\nexit 0\n' > "$work/not-executable-avrdude"
chmod 640 "$work/not-executable-avrdude"
for part in attiny13a attiny202; do
	: > "$log"
	if TEST_AVRDUDE="$work/not-executable-avrdude" \
			run_program "$part-program" >/dev/null 2>&1; then
		fail "$part-program accepted a non-executable programmer path"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program reached a programmer it had already rejected"
	fi
	checks=$((checks + 1))
done

# ---- The single-step goals keep their single-step meaning --------------------
: > "$log"
run_program attiny13a-fuses >/dev/null 2>&1
if [ "$(count_of '^AVRDUDE FUSE ')" -ne 1 ] || [ "$(count_of '^AVRDUDE FLASH ')" -ne 0 ]; then
	fail "attiny13a-fuses is no longer exactly one fuse write"
fi
checks=$((checks + 1))
: > "$log"
run_program attiny13a-flash >/dev/null 2>&1
if [ "$(count_of '^AVRDUDE FLASH ')" -ne 1 ] || [ "$(count_of '^AVRDUDE FUSE ')" -ne 0 ]; then
	fail "attiny13a-flash is no longer exactly one flash write"
fi
checks=$((checks + 1))

if [ "$failures" -ne 0 ]; then
	printf 'AVR program transaction order: %d checks, %d failures\n' "$checks" "$failures" >&2
	exit 1
fi
printf 'AVR program transaction order: %d checks, 0 failures\n' "$checks"
