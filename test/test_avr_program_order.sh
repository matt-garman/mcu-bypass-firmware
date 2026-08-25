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
#   SELECTED     VARIANT must be in the VARIANTS matrix rebuilt by this request;
#                an old selected HEX cannot satisfy a mismatched build.
#   FORCE        Classic programming refuses AVR_REBUILD_PREREQ=, so a stale
#                ELF/HEX pair cannot bypass the current build.
#   CURRENT      even a valid stale selected image is rebuilt before hardware.
#   NO-SIZE      a failed size report invokes avrdude ZERO times.
#   RECHECK      the final published HEX is revalidated before hardware.
#   REGULAR      a symlinked final HEX is never passed to avrdude.
#   INTERNAL     command-line values cannot replace derived image/action checks.
#   LITERAL      Make syntax in tool/programmer/fuse values remains inert data.
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
unset FAKE_CC_MODE FAKE_OBJCOPY_MODE FAKE_SIZE_MODE FAKE_IHEX_MODE \
	FAKE_SIZE_FAIL_MATCH FAKE_SYMLINK_FINAL
unset AVR_BUILD_DIR AVR_FW FW_BASE XT_BUILD_DIR XT_DFP AVRDUDE
# scripts/ci-local.sh exports STRICT_TOOLS=1; the NO-IMAGE case needs the
# ordinary skip policy, and pins what it needs explicitly.
unset STRICT_TOOLS

mkdir -p "$tools" "$classic_build" "$xt_build" \
	"$dfp/gcc/dev/attiny202/device-specs" "$dfp/include/avr"
: > "$dfp/gcc/dev/attiny202/device-specs/specs-attiny202"
: > "$dfp/include/avr/iotn202.h"
valid_hex="$work/valid.hex"
printf ':0100000001FE\n:00000001FF\n' > "$valid_hex"

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
case "${FAKE_SIZE_MODE:-pass}" in
	fail) exit 1 ;;
	fail-selected) case "$*" in *"$FAKE_SIZE_FAIL_MATCH"*) exit 1 ;; esac ;;
esac
printf 'AVR Memory Usage\nDevice: Unknown\n\nProgram: 100 bytes\nData: 8 bytes\n'
if [ "${FAKE_SIZE_MODE:-pass}" = symlink-final ]; then
	rm -f "$FAKE_SYMLINK_FINAL"
	ln -s "$FAKE_VALID_HEX" "$FAKE_SYMLINK_FINAL"
fi
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

cat > "$tools/ihex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path=$1
printf 'IHEX %s\n' "$path" >> "$FAKE_EVENT_LOG"
"$REAL_IHEX_VALIDATOR" "$path"
if [ "${FAKE_IHEX_MODE:-pass}" = reject-final ]; then
	case "$path" in *.tmp|*.tmp.*) : ;; *) exit 1 ;; esac
fi
EOF

# Classifies itself from its own argv, so a recipe cannot log a fuse write and
# then perform a flash one. `:m` is the fuse memory form, `flash:w:...:i` the
# image form -- the same two shapes test_fuse_injection_contract.py keys on.
cat > "$tools/avrdude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fuse_ops=0
flash_ops=0
read_ops=0
for arg in "$@"; do
	case "$arg" in
		flash:w:*:i) flash_ops=$((flash_ops + 1)) ;;
		*:w:*:m) fuse_ops=$((fuse_ops + 1)) ;;
		*:r:*) read_ops=$((read_ops + 1)) ;;
	esac
done
if [ "$fuse_ops" -gt 0 ] && [ "$flash_ops" -eq 0 ] && [ "$read_ops" -eq 0 ]; then
	kind=FUSE
elif [ "$flash_ops" -gt 0 ] && [ "$fuse_ops" -eq 0 ] && [ "$read_ops" -eq 0 ]; then
	kind=FLASH
elif [ "$read_ops" -gt 0 ] && [ "$fuse_ops" -eq 0 ] && [ "$flash_ops" -eq 0 ]; then
	kind=READ
elif [ "$fuse_ops" -gt 0 ] || [ "$flash_ops" -gt 0 ] || [ "$read_ops" -gt 0 ]; then
	kind=MIXED
else
	kind=OTHER
fi
printf 'AVRDUDE %s fuse_ops=%d flash_ops=%d read_ops=%d %s\n' \
	"$kind" "$fuse_ops" "$flash_ops" "$read_ops" "$*" >> "$FAKE_EVENT_LOG"
EOF
chmod 750 "$tools"/*

run_program() {
	local goal=$1; shift
	FAKE_EVENT_LOG="$log" FAKE_VALID_HEX="$valid_hex" \
	REAL_IHEX_VALIDATOR="$ROOT/scripts/validate-ihex.sh" \
	make --no-print-directory -C "$ROOT" "$goal" \
		AVR_BUILD_DIR="$classic_build" XT_BUILD_DIR="$xt_build" \
		XT_DFP="${TEST_DFP-$dfp}" \
		CC="$tools/cc" READELF="$tools/readelf" SIZE="$tools/size" \
		OBJCOPY="$tools/objcopy" IHEX_VALIDATOR="$tools/ihex" \
		AVRDUDE="${TEST_AVRDUDE-$tools/avrdude}" \
		"$@"
}

first_index() { grep -n -E "$1" "$log" | head -1 | cut -d: -f1; }
count_of()    { grep -c -E "$1" "$log" || true; }

reset_builds() {
	rm -rf "$classic_build" "$xt_build"
	mkdir -p "$classic_build" "$xt_build"
}

program_stem() {
	local part=$1 variant=$2
	if [ "$part" = attiny202 ]; then
		printf '%s/bypass-%s-%s' "$xt_build" "$part" "$variant"
	else
		printf '%s/bypass-%s-%s' "$classic_build" "$part" "$variant"
	fi
}

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
	others=$(count_of '^AVRDUDE (OTHER|READ|MIXED) ')
	expected_fuse_ops=2
	if [ "$part" = attiny202 ]; then expected_fuse_ops=7; fi

	if [ -z "$cc_at" ] || [ -z "$hex_at" ] || [ -z "$fuse_at" ] || [ -z "$flash_at" ]; then
		fail "$part-program did not record a build, a fuse write and a flash write"
	elif [ "$cc_at" -ge "$fuse_at" ] || [ "$hex_at" -ge "$fuse_at" ]; then
		fail "$part-program wrote fuses before the image was built and converted"
	elif [ "$fuse_at" -ge "$flash_at" ]; then
		fail "$part-program did not write fuses before flash"
	elif [ "$fuses" -ne 1 ] || [ "$flashes" -ne 1 ] || [ "$others" -ne 0 ]; then
		fail "$part-program ran $fuses fuse, $flashes flash and $others other programmer commands (want 1/1/0)"
	elif ! grep -q -E "^AVRDUDE FUSE fuse_ops=${expected_fuse_ops} flash_ops=0 read_ops=0 " "$log" \
			|| ! grep -q -E '^AVRDUDE FLASH fuse_ops=0 flash_ops=1 read_ops=0 ' "$log"; then
		fail "$part-program did not preserve its exact fuse/flash -U operation counts"
	fi
	checks=$((checks + 1))

	# The flash write must name the image the build actually produced.
	expected_hex=$(program_stem "$part" cd4053_simple).hex
	if ! grep -q -F "flash:w:$expected_hex:i" "$log"; then
		fail "$part-program flashed an image that is not this part's build product"
	fi
	checks=$((checks + 1))
done

# ---- CURRENT: a valid stale selected image is rebuilt before hardware --------
for part in attiny13a attiny45 attiny85 attiny202; do
	: > "$log"
	reset_builds
	stem=$(program_stem "$part" cd4053_simple)
	printf 'stale ELF\n' > "$stem.elf"
	cp "$valid_hex" "$stem.hex"
	if ! run_program "$part-program" VARIANT=cd4053_simple \
			VARIANTS=cd4053_simple >/dev/null 2>&1; then
		fail "$part-program did not replace valid stale selected artifacts"
	fi
	if [ "$(count_of '^CC ')" -eq 0 ]; then
		fail "$part-program reused a stale selected image instead of rebuilding it"
	fi
	if [ "$(count_of '^AVRDUDE FUSE ')" -ne 1 ] \
			|| [ "$(count_of '^AVRDUDE FLASH ')" -ne 1 ]; then
		fail "$part-program did not complete exactly one transaction after rebuilding"
	fi
	checks=$((checks + 1))
done

# ---- INTERNAL: callers cannot replace derived safety/action variables --------
for part in attiny13a attiny45 attiny85 attiny202; do
	: > "$log"
	reset_builds
	case "$part" in
		attiny202)
			prefix=XT
			internal_overrides=(
				"XT_AVRDUDE_FLAGS=-c injected -U flash:w:$work/injected.hex:i"
				"XT_PROGRAMMER=injected -U flash:w:$work/injected.hex:i"
				"XT_UPDI_PORT=/dev/null -U flash:w:$work/injected.hex:i"
				XT_AVRDUDE_PART=t13
				"XT_FUSE_WDTCFG=0x00:m -U flash:w:$work/injected.hex:i"
			)
			;;
		attiny13a)
			prefix=ATTINY13A
			internal_overrides=(
				"ATTINY13A_AVRDUDE_FLAGS=-c injected -U flash:w:$work/injected.hex:i"
				"AVR_PROGRAMMER=injected -U flash:w:$work/injected.hex:i"
				ATTINY13A_AVRDUDE_PART=t85
				"ATTINY13A_LFUSE=0x00:m -U flash:w:$work/injected.hex:i"
			)
			;;
		*)
			prefix=${part^^}
			n=${part#attiny}
			internal_overrides=(
				"AVR_PROGRAMMER=injected -U flash:w:$work/injected.hex:i"
				"part_$n=t13"
				"TINYX5_LFUSE=0x00:m -U flash:w:$work/injected.hex:i"
			)
			;;
	esac
	wrong_hex="$work/wrong-$part.hex"
	cp "$valid_hex" "$wrong_hex"
	if ! run_program "$part-program" VARIANT=cd4053_simple \
			VARIANTS=cd4053_simple \
			AVR_PROGRAM_IMAGE_CHECK=false AVR_PROGRAMMER_CHECK=false \
			"${prefix}_PROG_HEX=$wrong_hex" \
			"${prefix}_FUSE_WRITE=:" "${prefix}_FLASH_WRITE=:" \
			"${internal_overrides[@]}" \
			>/dev/null 2>&1; then
		fail "$part-program let command-line internal overrides break its transaction"
	fi
	expected_hex=$(program_stem "$part" cd4053_simple).hex
	expected_fuse_ops=2
	if [ "$part" = attiny202 ]; then expected_fuse_ops=7; fi
	if [ "$(count_of '^AVRDUDE FUSE ')" -ne 1 ] \
			|| [ "$(count_of '^AVRDUDE FLASH ')" -ne 1 ] \
			|| [ "$(count_of '^AVRDUDE (OTHER|READ|MIXED) ')" -ne 0 ] \
			|| ! grep -q -F "flash:w:$expected_hex:i" "$log" \
			|| ! grep -q -E "^AVRDUDE FUSE fuse_ops=${expected_fuse_ops} flash_ops=0 read_ops=0 " "$log" \
			|| ! grep -q -E '^AVRDUDE FLASH fuse_ops=0 flash_ops=1 read_ops=0 ' "$log"; then
		fail "$part-program did not preserve its canonical fuse/flash actions against internal overrides"
	fi
	checks=$((checks + 1))
done

# ---- LITERAL INPUTS: Make syntax in hardware inputs fails before work ---------
for spec in \
	IHEX_VALIDATOR:attiny13a AVRDUDE:attiny13a \
	AVR_PROGRAMMER:attiny13a ATTINY13A_LFUSE:attiny13a \
	TINYX5_LFUSE:attiny45 \
	XT_PROGRAMMER:attiny202 XT_UPDI_PORT:attiny202 \
	XT_FUSE_WDTCFG:attiny202; do
	tool_var=${spec%%:*}
	part=${spec#*:}
	: > "$log"
	reset_builds
	make_marker="$work/$tool_var-make-evaluation"
	stateful="\$(shell touch $make_marker)"
	payload="${stateful}injected"
	if run_program "$part-program" \
			VARIANT=cd4053_simple VARIANTS=cd4053_simple \
			"$tool_var=$payload" >/dev/null 2>&1; then
		fail "$part-program accepted stateful Make text in $tool_var"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ] || [ "$(count_of '^CC ')" -ne 0 ]; then
		fail "stateful $tool_var text reached build or programmer work"
	fi
	if [ -e "$make_marker" ]; then
		fail "stateful $tool_var text executed during Make expansion"
	fi
	checks=$((checks + 1))
done

# ---- SELECTED: stale images cannot satisfy a mismatched build matrix ---------
for part in attiny13a attiny45 attiny85 attiny202; do
	: > "$log"
	reset_builds
	stem=$(program_stem "$part" tq2_l2_5v_relay)
	printf 'stale ELF\n' > "$stem.elf"
	cp "$valid_hex" "$stem.hex"
	output="$work/$part-mismatched-matrix.log"
	if run_program "$part-program" VARIANT=tq2_l2_5v_relay \
			VARIANTS=cd4053_simple >"$output" 2>&1; then
		fail "$part-program accepted a stale selected image outside VARIANTS"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program invoked the programmer for a selected image outside VARIANTS"
	fi
	if [ "$(count_of '^CC ')" -ne 0 ]; then
		fail "$part-program started a build before rejecting its mismatched selectors"
	fi
	if ! grep -q 'VARIANT=tq2_l2_5v_relay is not included in VARIANTS=cd4053_simple' "$output"; then
		fail "$part-program did not diagnose the mismatched selected/build variants"
	fi
	checks=$((checks + 1))
done

# Nonempty and stateful forms must be sanitized before generated rules consume
# them, not merely diagnosed after their Make syntax has already executed.
for bad_rebuild in NOT_FORCE '$(eval override AVR_REBUILD_PREREQ := FORCE)'; do
	: > "$log"
	reset_builds
	stem=$(program_stem attiny13a tq2_l2_5v_relay)
	printf 'stale ELF\n' > "$stem.elf"
	cp "$valid_hex" "$stem.hex"
	output="$work/attiny13a-unsafe-rebuild-value.log"
	if run_program attiny13a-program VARIANT=tq2_l2_5v_relay \
			VARIANTS=tq2_l2_5v_relay "AVR_REBUILD_PREREQ=$bad_rebuild" \
			>"$output" 2>&1; then
		fail "attiny13a-program accepted unsafe AVR_REBUILD_PREREQ=$bad_rebuild"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ] || [ "$(count_of '^CC ')" -ne 0 ]; then
		fail "unsafe AVR_REBUILD_PREREQ=$bad_rebuild reached build or hardware work"
	fi
	if ! grep -q 'AVR_REBUILD_PREREQ must remain FORCE' "$output"; then
		fail "attiny13a-program did not diagnose unsafe AVR_REBUILD_PREREQ=$bad_rebuild"
	fi
	checks=$((checks + 1))
done

# ---- FORCE: Classic hardware goals cannot reuse a stale ELF/HEX pair ---------
for part in attiny13a attiny45 attiny85; do
	: > "$log"
	reset_builds
	stem=$(program_stem "$part" tq2_l2_5v_relay)
	printf 'stale ELF\n' > "$stem.elf"
	cp "$valid_hex" "$stem.hex"
	output="$work/$part-rebuild-override.log"
	if run_program "$part-program" VARIANT=tq2_l2_5v_relay \
			VARIANTS=tq2_l2_5v_relay AVR_REBUILD_PREREQ= \
			>"$output" 2>&1; then
		fail "$part-program accepted AVR_REBUILD_PREREQ= with stale artifacts"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program invoked the programmer after its forced rebuild was disabled"
	fi
	if [ "$(count_of '^CC ')" -ne 0 ]; then
		fail "$part-program started work before rejecting AVR_REBUILD_PREREQ="
	fi
	if ! grep -q 'AVR_REBUILD_PREREQ must remain FORCE' "$output"; then
		fail "$part-program did not diagnose its disabled forced rebuild"
	fi
	checks=$((checks + 1))
done

# ---- NO-SIZE: a failed resource report reaches no programmer -----------------
for part in attiny13a attiny45 attiny85 attiny202; do
	: > "$log"
	reset_builds
	if FAKE_SIZE_MODE=fail run_program "$part-program" \
			VARIANT=cd4053_simple VARIANTS=cd4053_simple \
			>/dev/null 2>&1; then
		fail "$part-program succeeded with a failing size tool"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program invoked the programmer after size validation failed"
	fi
	checks=$((checks + 1))
done

# A selected-image size failure must not be hidden by a later successful matrix
# entry. This is the multi-variant shape the singleton NO-SIZE cases cannot see.
for part in attiny13a attiny45 attiny85; do
	: > "$log"
	reset_builds
	if FAKE_SIZE_MODE=fail-selected \
			FAKE_SIZE_FAIL_MATCH="$part-cd4053_simple.elf" \
			run_program "$part-program" VARIANT=cd4053_simple \
			VARIANTS='cd4053_simple cd4053_with_mute tq2_l2_5v_relay' \
			>/dev/null 2>&1; then
		fail "$part-program masked the selected image's size failure"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program invoked the programmer after masking a size failure"
	fi
	checks=$((checks + 1))
done

# ---- RECHECK: reject a final image even when its build temporary passed ------
for part in attiny13a attiny45 attiny85 attiny202; do
	: > "$log"
	reset_builds
	if FAKE_IHEX_MODE=reject-final run_program "$part-program" \
			VARIANT=cd4053_simple VARIANTS=cd4053_simple \
			>/dev/null 2>&1; then
		fail "$part-program accepted a final HEX rejected by immediate revalidation"
	fi
	if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
		fail "$part-program invoked the programmer after final HEX validation failed"
	fi
	if ! grep -q -E "^IHEX .*${part}-cd4053_simple[.]hex$" "$log"; then
		fail "$part-program did not revalidate its published HEX"
	fi
	checks=$((checks + 1))
done

# ---- REGULAR: reject post-build replacement with a symlink -------------------
: > "$log"
reset_builds
stem=$(program_stem attiny13a cd4053_simple)
if FAKE_SIZE_MODE=symlink-final FAKE_SYMLINK_FINAL="$stem.hex" \
		run_program attiny13a-program VARIANT=cd4053_simple \
		VARIANTS=cd4053_simple >/dev/null 2>&1; then
	fail "attiny13a-program accepted a symlink substituted after the build"
fi
if [ "$(count_of '^AVRDUDE ')" -ne 0 ]; then
	fail "attiny13a-program invoked the programmer with a symlinked HEX"
fi
if [ ! -L "$stem.hex" ]; then
	fail "symlink substitution control did not reach the final image"
fi
checks=$((checks + 1))

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
