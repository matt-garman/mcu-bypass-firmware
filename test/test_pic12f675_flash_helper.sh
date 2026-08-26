#!/usr/bin/env bash
# Fake-programmer regression for the release-shipped PIC12F675 flashing helper.
#
# The helper writes silicon, and the one thing this repository cannot put in CI
# is silicon. So the properties that matter are proved against a stateful fake
# ipecmd (test/pic/fake_ipecmd.py) whose device memory persists across
# invocations and which records every argument vector it is handed:
#
#   1. ORDER. baseline read -> immediate re-read -> durable reservation -> ONE
#      write -> final read. The recorded vectors carry a witness flag saying
#      whether reservation.json existed when the tool was entered, so "durable
#      reservation precedes the write" is observed, not assumed.
#   2. ZERO WRITES ON EVERY REFUSAL. Each fail-closed precondition is driven
#      individually, and each asserts that no `-M` vector was ever constructed.
#      A guard that fires after the erase is not a guard.
#   3. DAMAGE IS DETECTED. Each way a real writer can destroy this part --
#      erased OSCCAL, wrong OSCCAL, erased BG, wrong bytes, silent no-op,
#      swapped device -- is injected and must produce a FAIL result, never a
#      PASS.
#   4. PENDING IS RECOVERABLE, READ-ONLY. A genuine SIGKILL between the write
#      and the readback leaves a reservation with no result; finalization
#      publishes one without ever constructing a write vector.
#   5. THE PINNED OBJECT IS THE ONE THAT RUNS. test/pic/flash_hook.py replaces
#      the tool, the Java runtime, the jar, the retained image and the evidence
#      directory INSIDE the window between the helper's last identity proof and
#      the child that consumes them. What the child actually got is read back
#      out of the fake device, not inferred.
#   6. PUBLICATION IS ALL OR NOTHING. The same driver fails and SIGKILLs inside
#      each durable step of result publication. Every outcome must be either one
#      complete immutable result or a PENDING transaction a read-only
#      finalization can still resolve -- never a truncated result.json.
#
# What it does NOT prove: that a real PICkit 3 preserves the trim. That is a
# bench question, gated separately in HARDWARE_VALIDATION_LOG.md.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/scripts/flash-pic12f675.py"
FAKE="$ROOT/test/pic/fake_ipecmd.py"
IMAGE_NAME=bypass-pic12f675-cd4053_simple.hex

checks=0
failures=0

# The helper refuses an evidence parent any other user could write into, so
# every fixture directory below must be created privately regardless of the
# runner's umask (containers frequently ship 0000).
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic12f675-flash.XXXXXX")
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

note() { printf '%s\n' "$*"; }

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	failures=$((failures + 1))
}

pass() { checks=$((checks + 1)); }

check() {
	local label=$1 condition=$2
	if [ "$condition" = 1 ]; then
		pass
	else
		fail "$label"
	fi
}

[ -f "$HELPER" ] && [ -x "$HELPER" ] \
	|| { printf 'FAIL: flashing helper is missing or not executable: %s\n' "$HELPER" >&2; exit 1; }
[ -f "$FAKE" ] && [ -x "$FAKE" ] \
	|| { printf 'FAIL: fake programmer is missing or not executable: %s\n' "$FAKE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 \
	|| { printf 'FAIL: python3 is required by the flashing-helper regression\n' >&2; exit 1; }

# The shipping image is built by XC8, which no host gate requires. Prefer a
# freshly built one; fall back to the newest released image so this gate runs
# everywhere `make test` does.
#
# PIC12F675_FLASH_IMAGES=build removes the fallback. Release qualification sets
# it, because there the images have just been rebuilt from the tagged source and
# a silent fall back to the PREVIOUS release's images would qualify the shipped
# helper against artifacts the candidate is not shipping.
require_build_images=0
case "${PIC12F675_FLASH_IMAGES:-}" in
"") ;;
build) require_build_images=1 ;;
*)
	printf 'FAIL: unsupported PIC12F675_FLASH_IMAGES=%s (expected empty or "build")\n' \
		"$PIC12F675_FLASH_IMAGES" >&2
	exit 1
	;;
esac

image_candidates() {
	printf '%s\n' "$ROOT/build_pic12f675/bypass-pic12f675-$1.hex"
	[ "$require_build_images" -eq 1 ] \
		|| printf '%s\n' "$ROOT/release/v0.9.9/bypass-pic12f675-$1.hex"
}

source_image=""
for candidate in $(image_candidates cd4053_simple); do
	if [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -s "$candidate" ]; then
		source_image=$candidate
		break
	fi
done
if [ -z "$source_image" ]; then
	if [ "$require_build_images" -eq 1 ]; then
		printf 'FAIL: PIC12F675_FLASH_IMAGES=build requires freshly built images in %s\n' \
			"$ROOT/build_pic12f675" >&2
	else
		printf 'FAIL: no PIC12F675 release image available to exercise the helper\n' >&2
	fi
	exit 1
fi

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

# A downloaded release bundle: the selected image, the helper, the checksum
# manifest the detached signature covers, and that signature.
make_bundle() {
	local dir=$1
	mkdir -p "$dir"
	cp -- "$source_image" "$dir/$IMAGE_NAME"
	cp -- "$HELPER" "$dir/flash-pic12f675.py"
	chmod 0755 "$dir/flash-pic12f675.py"
	( cd "$dir" && sha256sum -- "$IMAGE_NAME" flash-pic12f675.py > SHA256SUMS )
	printf -- '-----BEGIN PGP SIGNATURE-----\nnot a real signature\n-----END PGP SIGNATURE-----\n' \
		> "$dir/SHA256SUMS.asc"
}

# A sealed anonymous image cannot be rewritten by anyone, including the helper;
# a held image.hex descriptor cannot be REPLACED but its inode remains the
# owner's to edit. Which of the two the helper reaches for is a property of the
# host, so the expected value is derived here rather than asserted blind.
if python3 -c 'import os,sys; sys.exit(0 if hasattr(os, "memfd_create") else 1)'; then
	EXPECTED_PINNING=sealed
else
	EXPECTED_PINNING=retained-descriptor
fi

case_no=0
# Per-case private state: a fresh device, a fresh argument-vector log, and a
# fresh bundle, so no case can be satisfied by another case's leftovers.
new_case() {
	case_no=$((case_no + 1))
	CASE_DIR="$work/case-$case_no"
	mkdir -p "$CASE_DIR"
	BUNDLE="$CASE_DIR/bundle"
	make_bundle "$BUNDLE"
	DEVICE="$CASE_DIR/device.json"
	ARGVLOG="$CASE_DIR/argv.log"
	: > "$ARGVLOG"
	EVIDENCE="$CASE_DIR/evidence"
	IMAGE="$BUNDLE/$IMAGE_NAME"
	BUNDLE_HELPER="$BUNDLE/flash-pic12f675.py"
	# Only the cases that hand the helper a private copy of the programmer let
	# the fake move that copy underneath its own pathname.
	FAKE_SELF=""
	hook_reset
}

# test/pic/flash_hook.py runs the helper as a module and wraps ONE function, so
# a replacement or an I/O failure can be placed inside a window that has no
# externally observable edge. HOOK selects it; the FLASH_HOOK_* variables it
# reads are exported by the case and cleared here so no case inherits another's.
DRIVER="$ROOT/test/pic/flash_hook.py"
[ -f "$DRIVER" ] && [ -x "$DRIVER" ] \
	|| { printf 'FAIL: flashing-helper hook driver is missing or not executable: %s\n' "$DRIVER" >&2; exit 1; }

hook_reset() {
	HOOK=""
	unset FLASH_HOOK_SWAPS FLASH_HOOK_FAIL_OP FLASH_HOOK_FAIL \
		FLASH_HOOK_KILL_OP FLASH_HOOK_KILL
}
hook_reset

# Run one helper invocation against this case's fake device.
run_helper() {
	local faults=$1
	shift
	local -a launcher=(python3 "$BUNDLE_HELPER")
	# Same helper, same bundle binding -- the driver only wraps a function of the
	# module it imports, and computes the helper identity from that same file.
	[ -z "${HOOK:-}" ] || launcher=(python3 "$DRIVER" "$BUNDLE_HELPER")
	set +e
	# The interruption cases kill the helper outright, and the shell announces a
	# signalled child on ITS stderr, not the child's. Send that notice to the
	# case log so a deliberate SIGKILL does not look like a broken gate.
	{
		FAKE_IPE_STATE="$DEVICE" FAKE_IPE_LOG="$ARGVLOG" \
		FAKE_IPE_WITNESS="$EVIDENCE/reservation.json" \
		FAKE_IPE_SELF="$FAKE_SELF" \
		FAKE_IPE_FAULTS="$faults" \
			"${launcher[@]}" "$@" \
				> "$CASE_DIR/stdout.txt" 2> "$CASE_DIR/stderr.txt"
		RC=$?
	} 2>> "$CASE_DIR/stderr.txt"
	set -e
	OUT=$(cat "$CASE_DIR/stdout.txt" "$CASE_DIR/stderr.txt")
}

program_run() {
	run_helper "$1" program --image "$IMAGE" --ipecmd "$FAKE" \
		--evidence-dir "$EVIDENCE" "${@:2}"
}

writes() { grep -c -- $'\t-M\t' "$ARGVLOG" 2>/dev/null || true; }
reads() { grep -c -- '-GF' "$ARGVLOG" 2>/dev/null || true; }

assert_no_write() {
	local label=$1 count
	count=$(writes)
	if [ "$count" = 0 ]; then
		pass
	else
		fail "$label: the helper reached a device write ($count invocation(s))"
	fi
}

assert_rejects() {
	local label=$1 expected=$2
	if [ "$RC" -eq 2 ] && [[ "$OUT" == *"$expected"* ]]; then
		pass
	else
		fail "$label: expected exit 2 and '$expected'; got exit $RC: $OUT"
	fi
	assert_no_write "$label"
}

json_field() {
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], "<absent>"))' \
		"$1" "$2"
}

result_field() { json_field "$EVIDENCE/result.json" "$1"; }

reservation_field() { json_field "$EVIDENCE/reservation.json" "$1"; }

# What the fake device recorded about the call it actually received: the digest
# of the image the WRITER opened, and the addresses a fault chose. Read back
# rather than assumed, which is the only way a swapped-in file is distinguished
# from the pinned one.
device_field() { json_field "$DEVICE" "$1"; }

sha256_of() { sha256sum -- "$1" | cut -d' ' -f1; }

# One publication remnant proves the temporary-file route was taken; the absence
# of the final name proves nothing partial was published under it.
publication_remnants() {
	find "$EVIDENCE" -maxdepth 1 -name 'result.json.*.tmp' 2>/dev/null | wc -l
}

assert_fail_result() {
	local label=$1 expected=$2 status
	if [ "$RC" -ne 1 ]; then
		fail "$label: expected a published FAIL (exit 1); got exit $RC: $OUT"
		return
	fi
	pass
	status=$(result_field status)
	check "$label: result.json records FAIL" "$([ "$status" = FAIL ] && echo 1 || echo 0)"
	if [[ "$OUT" == *"$expected"* ]]; then
		pass
	else
		fail "$label: FAIL did not name '$expected': $OUT"
	fi
}

# ---------------------------------------------------------------------------
# 1. the accepted transaction
# ---------------------------------------------------------------------------
note '== accepted transaction =='
new_case
program_run ''
check "happy path exits 0" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)"
check "happy path reports PASS" \
	"$([[ "$OUT" == *"PIC12F675_FLASH_RESULT status=PASS"* ]] && echo 1 || echo 0)"
check "happy path announces its reservation" \
	"$([[ "$OUT" == *"PIC12F675_FLASH_RESERVED"* ]] && echo 1 || echo 0)"
check "happy path says PASS is not proof the writer is safe" \
	"$([[ "$OUT" == *"not proof that this writer preserves calibration"* ]] && echo 1 || echo 0)"

# The transaction order, read straight off what the operating system received.
mapfile -t vectors < "$ARGVLOG"
check "exactly five tool invocations" \
	"$([ "${#vectors[@]}" -eq 5 ] && echo 1 || echo 0)"
check "invocation 1 is the version probe, before any device access" \
	"$([[ "${vectors[0]}" == *$'\t-?' ]] && echo 1 || echo 0)"
check "invocation 2 is the baseline read" \
	"$([[ "${vectors[1]}" == "witness=0"*"-GF$EVIDENCE/baseline.hex" ]] && echo 1 || echo 0)"
check "invocation 3 is the immediate pre-write read" \
	"$([[ "${vectors[2]}" == "witness=0"*"-GF$EVIDENCE/prewrite.hex" ]] && echo 1 || echo 0)"
check "invocation 4 is the single write" \
	"$([[ "${vectors[3]}" == *$'\t-M\t-Y\t-OL' ]] && echo 1 || echo 0)"
check "the write is reached only after a durable reservation exists" \
	"$([[ "${vectors[3]}" == "witness=1"* ]] && echo 1 || echo 0)"
# The write names a DESCRIPTOR this helper is holding open, not a pathname that
# could be pointed at another file between the last check and the exec. What the
# writer actually opened is then read back out of the device model, because an
# argv alone would not distinguish a pinned descriptor from a lucky one.
check "the write consumes a pinned descriptor, not a replaceable pathname" \
	"$([[ "${vectors[3]}" == *$'\t-F/proc/self/fd/'* ]] && echo 1 || echo 0)"
check "the writer received exactly the retained snapshot bytes" \
	"$([ "$(device_field image_sha256)" = "$(sha256_of "$EVIDENCE/image.hex")" ] && echo 1 || echo 0)"
check "the write requests no programmer-supplied power" \
	"$([[ "${vectors[3]}" != *$'\t-W5'* ]] && echo 1 || echo 0)"
check "invocation 5 is the final full-device read" \
	"$([[ "${vectors[4]}" == *"-GF$EVIDENCE/postread.hex" ]] && echo 1 || echo 0)"
check "exactly one write reached the device" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

check "reservation is PENDING" \
	"$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(1 if r["status"]=="PENDING" and r["record_type"]=="reservation" else 0)' "$EVIDENCE/reservation.json")"
check "reservation binds the image digest" \
	"$(python3 -c 'import hashlib,json,sys; r=json.load(open(sys.argv[1])); print(1 if r["image_sha256"]==hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest() else 0)' "$EVIDENCE/reservation.json" "$IMAGE")"
check "reservation binds the programmer identity" \
	"$(python3 -c 'import hashlib,json,sys; r=json.load(open(sys.argv[1])); print(1 if r["programmer_sha256"]==hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest() else 0)' "$EVIDENCE/reservation.json" "$FAKE")"
check "reservation records the externally powered arrangement" \
	"$([ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["power_mode"])' "$EVIDENCE/reservation.json")" = external ] && echo 1 || echo 0)"
# Exact, not "greater than zero". The whole point of comparing the WHOLE device
# is that a PASS accounts for every word this part holds below the calibration
# word, so the count is checked against the part's geometry; a comparison that
# stopped early could satisfy "greater than zero" while proving nothing.
check "result verifies every program word below the calibration word" \
	"$([ "$(result_field verified_program_words)" = 1023 ] \
		&& [ "$(result_field required_program_words)" = 1023 ] \
		&& [ "$(result_field verified_config_word)" = True ] && echo 1 || echo 0)"
check "the reservation records how the image was pinned for the writer" \
	"$([ "$(reservation_field image_pinning)" = "$EXPECTED_PINNING" ] && echo 1 || echo 0)"
check "result carries no failures" \
	"$([ "$(result_field failures)" = "[]" ] && echo 1 || echo 0)"
check "the original device export is retained" \
	"$([ -s "$EVIDENCE/baseline.hex" ] && echo 1 || echo 0)"
for retained in reservation.json result.json image.hex baseline.hex baseline.log \
		prewrite.hex prewrite.log program.log postread.hex postread.log; do
	check "evidence retains $retained read-only" \
		"$([ -f "$EVIDENCE/$retained" ] && [ ! -w "$EVIDENCE/$retained" ] && echo 1 || echo 0)"
done

# A published result is immutable, and a completed directory is not a workspace.
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" --evidence-dir "$EVIDENCE"
check "a second transaction into a used evidence directory is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"evidence path already exists"* ]] && echo 1 || echo 0)"
check "the refused retry issued no further write" \
	"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalizing a completed transaction is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"already has a published result"* ]] && echo 1 || echo 0)"
check "the refused finalization issued no further write" \
	"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

# The RUNNING helper is bound to the selected bundle's signed checksum wherever
# it lives. Location is not the property that matters: a byte-identical copy
# outside the bundle IS the published tool, and a copy inside one is not the
# published tool if its bytes differ. Binding on location instead let an edited
# off-bundle helper program a signed image, which is what these four prove.
new_case
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" --evidence-dir "$EVIDENCE"
BUNDLE_HELPER=$HELPER
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" --evidence-dir "$CASE_DIR/evidence2"
check "a byte-identical helper outside the bundle programs the same image" \
	"$([ "$RC" -eq 0 ] && echo 1 || echo 0)"
check "the transaction records the helper as checksum-bound" \
	"$([ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["helper_checksum_bound"])' "$CASE_DIR/evidence2/reservation.json")" = True ] && echo 1 || echo 0)"

new_case
cp -- "$HELPER" "$CASE_DIR/flash-pic12f675.py"
printf '\n# an off-bundle edit\n' >> "$CASE_DIR/flash-pic12f675.py"
chmod 0755 "$CASE_DIR/flash-pic12f675.py"
BUNDLE_HELPER="$CASE_DIR/flash-pic12f675.py"
program_run ''
assert_rejects "an edited helper run from outside the bundle" \
	"does not match its signed checksum"

new_case
cp -- "$BUNDLE_HELPER" "$CASE_DIR/flash.py"
chmod 0755 "$CASE_DIR/flash.py"
BUNDLE_HELPER="$CASE_DIR/flash.py"
program_run ''
assert_rejects "the published helper running under another name" \
	"publishes these exact bytes as"

new_case
cp -- "$HELPER" "$CASE_DIR/other-flasher.py"
printf '\n# not the published tool\n' >> "$CASE_DIR/other-flasher.py"
chmod 0755 "$CASE_DIR/other-flasher.py"
BUNDLE_HELPER="$CASE_DIR/other-flasher.py"
program_run ''
assert_rejects "a helper this release never published" \
	"not an artifact of this release"

# Every shipping variant must be programmable by the tool that ships beside it.
# An output stage whose image the helper refuses would be a release-blocking
# defect that no other lane can see: the image gates check the BUILD, and this
# checks the one program allowed to write it.
note '== every shipping variant =='
for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
	variant_image=""
	for candidate in $(image_candidates "$variant"); do
		if [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -s "$candidate" ]; then
			variant_image=$candidate
			break
		fi
	done
	if [ -z "$variant_image" ]; then
		fail "no PIC12F675 $variant image available to exercise the helper"
		continue
	fi
	new_case
	cp -- "$variant_image" "$BUNDLE/bypass-pic12f675-$variant.hex"
	( cd "$BUNDLE" && sha256sum -- "bypass-pic12f675-$variant.hex" \
		flash-pic12f675.py > SHA256SUMS )
	IMAGE="$BUNDLE/bypass-pic12f675-$variant.hex"
	program_run ''
	check "the shipping $variant image programs to PASS" \
		"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
	# Each shipping image occupies a different, sparse part of this device, so the
	# count that accompanies a PASS has to be the same whole-device total for all
	# three -- not the number of words that image happens to supply.
	check "the shipping $variant image verifies every program word" \
		"$([ "$(result_field verified_program_words)" = 1023 ] \
			&& [ "$(result_field verified_config_word)" = True ] && echo 1 || echo 0)"
done

# ---------------------------------------------------------------------------
# 2. bundle-integrity refusals -- none may reach a write
# ---------------------------------------------------------------------------
note '== bundle integrity =='

new_case
rm -f "$BUNDLE/SHA256SUMS"
program_run ''
assert_rejects "missing SHA256SUMS" "release SHA256SUMS is unavailable"

new_case
rm -f "$BUNDLE/SHA256SUMS.asc"
program_run ''
assert_rejects "missing detached signature" "SHA256SUMS.asc"

new_case
grep -v "$IMAGE_NAME" "$BUNDLE/SHA256SUMS" > "$BUNDLE/SHA256SUMS.new"
mv "$BUNDLE/SHA256SUMS.new" "$BUNDLE/SHA256SUMS"
program_run ''
assert_rejects "image absent from SHA256SUMS" "does not list $IMAGE_NAME"

new_case
printf ':00000001FF\n' >> "$IMAGE"
program_run ''
assert_rejects "image digest drift" "does not match its signed checksum"

new_case
printf 'not a checksum line\n' >> "$BUNDLE/SHA256SUMS"
program_run ''
assert_rejects "malformed SHA256SUMS entry" "is not a sha256sum entry"

new_case
head -1 "$BUNDLE/SHA256SUMS" >> "$BUNDLE/SHA256SUMS"
program_run ''
assert_rejects "duplicate SHA256SUMS entry" "twice"

new_case
printf '\n# appended\n' >> "$BUNDLE_HELPER"
( cd "$BUNDLE" && sha256sum -- "$IMAGE_NAME" > SHA256SUMS )
printf '0000000000000000000000000000000000000000000000000000000000000000  flash-pic12f675.py\n' \
	>> "$BUNDLE/SHA256SUMS"
program_run ''
assert_rejects "helper digest drift inside a bundle" "flashing helper does not match its signed checksum"

new_case
mv "$IMAGE" "$BUNDLE/firmware.hex"
sed -i "s/$IMAGE_NAME/firmware.hex/" "$BUNDLE/SHA256SUMS"
IMAGE="$BUNDLE/firmware.hex"
program_run ''
assert_rejects "unreleased image basename" "not a released PIC12F675 image basename"

new_case
mv "$IMAGE" "$CASE_DIR/real.hex"
ln -s "$CASE_DIR/real.hex" "$IMAGE"
program_run ''
assert_rejects "image is a symbolic link" "is a symbolic link"

# ---------------------------------------------------------------------------
# 3. image-safety refusals -- none may reach a write
# ---------------------------------------------------------------------------
note '== image safety =='

# Rewrite the bundle image, then re-checksum it so the refusal under test is the
# image content and not the digest binding proved above.
reimage() {
	python3 - "$IMAGE" "$1" <<'PY'
import sys
records = sys.argv[2].split("|")
with open(sys.argv[1], "w") as handle:
    handle.write("\n".join(records) + "\n")
PY
	( cd "$BUNDLE" && sha256sum -- "$IMAGE_NAME" flash-pic12f675.py > SHA256SUMS )
}

# One valid data record plus the reviewed CONFIG word, as a base to mutate.
ihex_record() {
	python3 - "$@" <<'PY'
import sys
address = int(sys.argv[1], 16)
rtype = int(sys.argv[2], 16)
payload = bytes.fromhex(sys.argv[3])
record = bytes([len(payload), (address >> 8) & 0xFF, address & 0xFF, rtype]) + payload
checksum = (-sum(record)) & 0xFF
print(":" + (record + bytes([checksum])).hex().upper())
PY
}
CODE=$(ihex_record 0000 00 00280028)
CONFIG=$(ihex_record 400E 00 CC31)
EOFREC=':00000001FF'

new_case
reimage "$CODE|$CONFIG|$EOFREC"
program_run ''
check "a minimal well-formed image is accepted" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)"

new_case
CAL=$(ihex_record 07FE 00 3434)
reimage "$CODE|$CAL|$CONFIG|$EOFREC"
program_run ''
assert_rejects "image programs the OSCCAL word" "programs the OSCCAL calibration word 0x3FF"

new_case
EEPROM=$(ihex_record 4200 00 FF3F)
reimage "$CODE|$CONFIG|$EEPROM|$EOFREC"
program_run ''
assert_rejects "image writes EEPROM" "outside the program memory this release programs"

new_case
USERID=$(ihex_record 4000 00 FF3F)
reimage "$CODE|$CONFIG|$USERID|$EOFREC"
program_run ''
assert_rejects "image writes a user ID word" "outside the program memory this release programs"

new_case
DEVID=$(ihex_record 400C 00 C00F)
reimage "$CODE|$CONFIG|$DEVID|$EOFREC"
program_run ''
assert_rejects "image writes the device ID word" "outside the program memory this release programs"

new_case
WRONGCFG=$(ihex_record 400E 00 CC30)
reimage "$CODE|$WRONGCFG|$EOFREC"
program_run ''
assert_rejects "image carries an unreviewed CONFIG word" "not this release's reviewed"

new_case
reimage "$CODE|$EOFREC"
program_run ''
assert_rejects "image carries no CONFIG word" "carries no CONFIG word at 0x2007"

new_case
reimage "$CODE|$CODE|$CONFIG|$EOFREC"
program_run ''
assert_rejects "image writes one address twice" "twice"

new_case
BADSUM=${CODE%??}00
reimage "$BADSUM|$CONFIG|$EOFREC"
program_run ''
assert_rejects "image record has a bad checksum" "bad checksum"

new_case
reimage "$CODE|$CONFIG"
program_run ''
assert_rejects "image has no EOF record" "has no EOF record"

new_case
reimage "$CODE|$EOFREC|$CONFIG"
program_run ''
assert_rejects "image has a record after EOF" "record after its EOF record"

new_case
UNSUPPORTED=$(ihex_record 0000 03 0000FFFF)
reimage "$CODE|$UNSUPPORTED|$CONFIG|$EOFREC"
program_run ''
assert_rejects "image uses an unsupported record type" "unsupported record type"

new_case
FARSEGMENT=$(ihex_record 0000 04 0001)
reimage "$FARSEGMENT|$CODE|$CONFIG|$EOFREC"
program_run ''
assert_rejects "image selects a far linear address segment" "extended linear address segment"

new_case
reimage "$CONFIG|$EOFREC"
program_run ''
assert_rejects "image programs no program memory" "contains no program memory words"

# ---------------------------------------------------------------------------
# 4. identity, tool and path refusals -- none may reach a write
# ---------------------------------------------------------------------------
note '== identity and tool =='

new_case
program_run '' --part PIC12F683
assert_rejects "a different part" "programs PIC12F675 only"

new_case
program_run '' --tool PK4
assert_rejects "a different tool kind" "drives a PICkit 3"

new_case
program_run '' --power programmer
assert_rejects "programmer-supplied power" "the externally powered arrangement (--power external) is the only supported one"

new_case
run_helper '' program --image "$IMAGE" --ipecmd "$CASE_DIR/absent-ipecmd" \
	--evidence-dir "$EVIDENCE"
assert_rejects "an ipecmd that does not exist" "ipecmd is unavailable"

new_case
cp "$FAKE" "$CASE_DIR/ipecmd"
chmod 0644 "$CASE_DIR/ipecmd"
run_helper '' program --image "$IMAGE" --ipecmd "$CASE_DIR/ipecmd" \
	--evidence-dir "$EVIDENCE"
assert_rejects "an ipecmd that is not executable" "ipecmd is not executable"

new_case
program_run 'version:6.25'
assert_rejects "MPLAB X 6.25, which dropped PICkit 3" "this helper supports 6.20"

new_case
program_run 'version:5.50'
assert_rejects "an older MPLAB X" "this helper supports 6.20"

new_case
program_run 'noversion:1'
assert_rejects "an unrecognizable version banner" "no recognizable MPLAB X version banner"

new_case
mkdir -p "$EVIDENCE"
program_run ''
assert_rejects "an evidence directory that already exists" "evidence path already exists"

new_case
ln -s "$CASE_DIR" "$EVIDENCE"
program_run ''
assert_rejects "an evidence path that is a symbolic link" "evidence path already exists"

new_case
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" \
	--evidence-dir "$CASE_DIR/absent/evidence"
assert_rejects "an evidence parent that does not exist" "parent is unavailable"

# ---------------------------------------------------------------------------
# 4b. the supported java -jar form -- the same matrix through a second binary
# ---------------------------------------------------------------------------
note '== the supported java -jar form =='

JAVA="$ROOT/test/pic/fake_java.py"
[ -f "$JAVA" ] && [ -x "$JAVA" ] \
	|| { printf 'FAIL: fake Java runtime is missing or not executable: %s\n' "$JAVA" >&2; exit 1; }

# A jar is data, never executed directly, so it is deliberately not +x: a helper
# that required the executable bit here would reject every real ipecmd.jar.
jar_case() {
	new_case
	JAR="$CASE_DIR/ipecmd.jar"
	cp -- "$FAKE" "$JAR"
	chmod 0644 "$JAR"
}

jar_run() {
	run_helper "$1" program --image "$IMAGE" --ipecmd "$JAR" --java "$JAVA" \
		--evidence-dir "$EVIDENCE"
}

jar_case
jar_run ''
check "the java -jar form completes the transaction" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "the jar form writes exactly once" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"
check "the reservation records the jar form" \
	"$([ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["programmer_kind"])' "$EVIDENCE/reservation.json")" = jar ] && echo 1 || echo 0)"
check "the reservation pins the Java runtime that ran the jar" \
	"$(python3 -c 'import hashlib,json,sys; r=json.load(open(sys.argv[1])); print(1 if r["programmer_java_sha256"]==hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest() else 0)' "$EVIDENCE/reservation.json" "$JAVA")"

jar_case
run_helper '' program --image "$IMAGE" --ipecmd "$JAR" \
	--java "$CASE_DIR/absent-java" --evidence-dir "$EVIDENCE"
assert_rejects "a jar with no Java runtime" "needs a Java runtime"

jar_case
cp -- "$JAVA" "$CASE_DIR/java"
chmod 0644 "$CASE_DIR/java"
run_helper '' program --image "$IMAGE" --ipecmd "$JAR" --java "$CASE_DIR/java" \
	--evidence-dir "$EVIDENCE"
assert_rejects "a Java runtime that is not executable" "needs a Java runtime"

jar_case
jar_run 'version:6.25'
assert_rejects "MPLAB X 6.25 through the jar form" "this helper supports 6.20"

jar_case
jar_run 'noosccal:0'
assert_rejects "a device with no factory trim, through the jar form" \
	"contains no complete OSCCAL"

jar_case
jar_run 'eraseosccal:1'
assert_fail_result "an erased OSCCAL through the jar form" "OSCCAL word changed"

# A PENDING jar transaction reserved a jar AND a Java runtime, and both have to
# be the ones that come back.
jar_case
jar_run 'killparent:program'
check "an interrupted jar transaction leaves a PENDING reservation" \
	"$([ -s "$EVIDENCE/reservation.json" ] && [ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
cp -- "$JAVA" "$CASE_DIR/other-java"
printf '\n# a different runtime\n' >> "$CASE_DIR/other-java"
chmod 0755 "$CASE_DIR/other-java"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$JAR" \
	--java "$CASE_DIR/other-java"
check "finalizing a jar transaction with a different Java runtime is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"Java runtime is not the one this transaction reserved"* ]] && echo 1 || echo 0)"
check "that refusal published no result" \
	"$([ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$JAR" --java "$JAVA"
check "the reserved jar and Java runtime finalize it read-only" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "jar finalization never wrote" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 4c. the programmer must still be the programmer at the instant it is used
# ---------------------------------------------------------------------------
note '== programmer identity at the instant of use =='

# The fake moves ITS OWN pathname on cue, which is the only way to hit the
# window between "these bytes were hashed" and "this name was executed". Both
# cases fire on the pre-write read, so the next command would have been the
# write: a guard that noticed afterwards would not be a guard.
tool_case() {
	new_case
	TOOL_COPY="$CASE_DIR/ipecmd"
	cp -- "$FAKE" "$TOOL_COPY"
	chmod 0755 "$TOOL_COPY"
	FAKE_SELF=$TOOL_COPY
}

tool_case
run_helper 'replacetool:read1' program --image "$IMAGE" --ipecmd "$TOOL_COPY" \
	--evidence-dir "$EVIDENCE"
assert_rejects "a programmer replaced behind its own pathname" \
	"was replaced between its identity check"

tool_case
run_helper 'edittool:read1' program --image "$IMAGE" --ipecmd "$TOOL_COPY" \
	--evidence-dir "$EVIDENCE"
assert_rejects "a programmer edited in place mid-transaction" \
	"changed on disk between its identity check"

# ---------------------------------------------------------------------------
# 4e. the pinned object is the one that runs -- the check-to-use window
# ---------------------------------------------------------------------------
note '== the check-to-use window =='

# 4c proves the helper NOTICES a tool that moved between two invocations. That
# is a different property from this one. Here the replacement lands after the
# final identity proof of the invocation about to happen, where no further check
# can run: the only thing that can still save the transaction is that the child
# was handed a descriptor rather than a name. Each case therefore asserts what
# actually ran or was read, and asserts that the replacement really did land, so
# a case cannot pass by failing to fire.
swap_after_final_check() {
	HOOK=1
	export FLASH_HOOK_SWAPS=$1
}

make_decoy_tool() {
	cat > "$1" <<'SH'
#!/bin/sh
printf 'DECOY TOOL RAN\n'
exit 0
SH
	chmod 0755 "$1"
}

# The write transcript is the child's own stdout. A decoy that was exec'd says
# so there; the pinned fake says "Programming/Verify complete". Requiring BOTH
# keeps the check from passing because no write happened at all.
decoy_silent() {
	if [ -f "$EVIDENCE/program.log" ] \
			&& grep -q 'Programming/Verify complete' "$EVIDENCE/program.log" \
			&& ! grep -q 'DECOY TOOL RAN' "$EVIDENCE/program.log"; then
		echo 1
	else
		echo 0
	fi
}

# An image that programs word 0x3FF -- precisely what validate_release_image()
# refuses -- so a swap that reached the writer would destroy the factory trim
# the whole transaction exists to preserve.
make_calibration_image() {
	local cal
	cal=$(ihex_record 07FE 00 3434)
	printf '%s\n%s\n%s\n%s\n' "$CODE" "$cal" "$CONFIG" "$EOFREC" > "$1"
}

tool_case
make_decoy_tool "$CASE_DIR/decoy"
# Captured before the run: the swap MOVES the decoy onto the tool's pathname, so
# afterwards only this digest can still say whether it landed there.
decoy_sha=$(sha256_of "$CASE_DIR/decoy")
swap_after_final_check "[[\"$CASE_DIR/decoy\", \"$TOOL_COPY\"]]"
run_helper '' program --image "$IMAGE" --ipecmd "$TOOL_COPY" \
	--evidence-dir "$EVIDENCE"
hook_reset
# What ran is read out of the retained transcript, which is the child's own
# stdout: the decoy announces itself there if it is ever exec'd.
check "an ipecmd replaced after its final identity proof never executes" \
	"$(decoy_silent)"
check "the pinned ipecmd performed the write instead" \
	"$([ "$(writes)" = 1 ] && [ "$(device_field programs)" = 1 ] && echo 1 || echo 0)"
check "the replacement really did land on the tool's pathname" \
	"$([ "$(sha256_of "$TOOL_COPY")" = "$decoy_sha" ] && echo 1 || echo 0)"
check "the moved installation is reported rather than driven further" \
	"$([ "$RC" -eq 1 ] && [[ "$OUT" == *"was replaced between its identity check"* ]] && echo 1 || echo 0)"

jar_case
make_decoy_tool "$CASE_DIR/decoy"
decoy_sha=$(sha256_of "$CASE_DIR/decoy")
swap_after_final_check "[[\"$CASE_DIR/decoy\", \"$JAR\"]]"
jar_run ''
hook_reset
check "a jar replaced after its final identity proof is never loaded" \
	"$(decoy_silent)"
check "the pinned jar performed the write instead" \
	"$([ "$(writes)" = 1 ] && [ "$(device_field programs)" = 1 ] && echo 1 || echo 0)"
check "the jar replacement really did land" \
	"$([ "$(sha256_of "$JAR")" = "$decoy_sha" ] && echo 1 || echo 0)"

jar_case
cp -- "$JAVA" "$CASE_DIR/java-copy"
chmod 0755 "$CASE_DIR/java-copy"
make_decoy_tool "$CASE_DIR/decoy"
swap_after_final_check "[[\"$CASE_DIR/decoy\", \"$CASE_DIR/java-copy\"]]"
run_helper '' program --image "$IMAGE" --ipecmd "$JAR" \
	--java "$CASE_DIR/java-copy" --evidence-dir "$EVIDENCE"
hook_reset
check "a Java runtime replaced after its final identity proof never executes" \
	"$(decoy_silent)"
check "the pinned Java runtime performed the write instead" \
	"$([ "$(writes)" = 1 ] && [ "$(device_field programs)" = 1 ] && echo 1 || echo 0)"

new_case
make_calibration_image "$CASE_DIR/calibration.hex"
calibration_sha=$(sha256_of "$CASE_DIR/calibration.hex")
swap_after_final_check "[[\"$CASE_DIR/calibration.hex\", \"$EVIDENCE/image.hex\"]]"
program_run ''
hook_reset
check "an image swapped over the retained snapshot never reaches the writer" \
	"$([ "$(device_field image_sha256)" = "$(sha256_of "$IMAGE")" ] && echo 1 || echo 0)"
check "the swapped image really did replace the retained file" \
	"$([ "$(sha256_of "$EVIDENCE/image.hex")" = "$calibration_sha" ] && echo 1 || echo 0)"
check "the pre-write image guards are not bypassed by the race" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "the device's factory calibration word is untouched" \
	"$([ "$(result_field post_osccal_word)" = "$(result_field baseline_osccal_word)" ] && echo 1 || echo 0)"

# The longest version of the same window: not the file, the DIRECTORY it sits
# in. Renaming the evidence directory and recreating its name over a decoy makes
# every remaining pathname in the transaction resolve somewhere else.
new_case
mkdir -p "$CASE_DIR/decoy-evidence"
make_calibration_image "$CASE_DIR/decoy-evidence/image.hex"
swap_after_final_check \
	"[[\"$EVIDENCE\", \"$CASE_DIR/moved\"], [\"$CASE_DIR/decoy-evidence\", \"$EVIDENCE\"]]"
program_run ''
hook_reset
check "an evidence directory renamed mid-transaction does not redirect the write" \
	"$([ "$(device_field image_sha256)" = "$(sha256_of "$IMAGE")" ] && echo 1 || echo 0)"
check "the rename really did happen" \
	"$([ -f "$CASE_DIR/moved/reservation.json" ] && echo 1 || echo 0)"
check "the transaction keeps writing evidence into the directory it opened" \
	"$([ -f "$CASE_DIR/moved/result.json" ] && [ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
check "a readback it can no longer reach is a published FAIL, not a PASS" \
	"$([ "$RC" -eq 1 ] \
		&& [ "$(json_field "$CASE_DIR/moved/result.json" status)" = FAIL ] && echo 1 || echo 0)"
check "the hijacked directory still wrote exactly once" \
	"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 4d. unsafe evidence and input paths -- none may reach a write
# ---------------------------------------------------------------------------
note '== unsafe paths =='

new_case
mkdir -p "$CASE_DIR/open-parent"
chmod 0777 "$CASE_DIR/open-parent"
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" \
	--evidence-dir "$CASE_DIR/open-parent/evidence"
assert_rejects "an evidence parent any user could write into" "group/other-writable"

# ... but the sticky bit is what makes a shared directory safe, and refusing
# /tmp itself would push operators somewhere worse.
new_case
mkdir -p "$CASE_DIR/sticky-parent"
chmod 1777 "$CASE_DIR/sticky-parent"
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" \
	--evidence-dir "$CASE_DIR/sticky-parent/evidence"
check "a sticky world-writable parent is accepted" \
	"$([ "$RC" -eq 0 ] && echo 1 || echo 0)"

new_case
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" --evidence-dir /
assert_rejects "an evidence path naming no new directory" \
	"does not name a new directory"

new_case
: > "$CASE_DIR/plain-file"
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" \
	--evidence-dir "$CASE_DIR/plain-file/evidence"
assert_rejects "an evidence parent that is a regular file" \
	"parent is not a directory"

new_case
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" --evidence-dir "$EVIDENCE/"
check "a trailing separator still names a new directory" \
	"$([ "$RC" -eq 0 ] && [ -d "$EVIDENCE" ] && echo 1 || echo 0)"

new_case
rm -f "$IMAGE"
mkdir -p "$IMAGE"
program_run ''
assert_rejects "an image path that is a directory" \
	"selected release image is not a regular file"

new_case
mv "$BUNDLE/SHA256SUMS" "$CASE_DIR/sums"
ln -s "$CASE_DIR/sums" "$BUNDLE/SHA256SUMS"
program_run ''
assert_rejects "a symlinked checksum manifest" \
	"release SHA256SUMS is a symbolic link"

new_case
mkdir -p "$CASE_DIR/ipecmd-dir"
run_helper '' program --image "$IMAGE" --ipecmd "$CASE_DIR/ipecmd-dir" \
	--evidence-dir "$EVIDENCE"
assert_rejects "an ipecmd that is a directory" "ipecmd is not a regular file"

# ---------------------------------------------------------------------------
# 5. pre-write device refusals -- none may reach a write
# ---------------------------------------------------------------------------
note '== pre-write device state =='

new_case
program_run 'readfail:0'
assert_rejects "a failed baseline read" "baseline read failed"

new_case
program_run 'noexport:0'
assert_rejects "a baseline read that exported nothing" "baseline device export is unavailable"

new_case
program_run 'badexport:0'
assert_rejects "a baseline export that is not Intel HEX" "does not start with"

new_case
program_run 'noid:0'
assert_rejects "a baseline transcript with no device identity" "Device ID and Device Revision"

new_case
program_run 'noosccal:0'
assert_rejects "a device with no factory calibration word" "contains no complete OSCCAL"

new_case
program_run 'readfail:1'
assert_rejects "a failed immediate pre-write read" "prewrite read failed"

new_case
program_run 'drift:1'
assert_rejects "a device that changed between the two pre-write reads" \
	"changed between the baseline read and the immediate"

# ---------------------------------------------------------------------------
# 5b. full-device export integrity -- a baseline that cannot be trusted is not
#     a baseline, and no write follows one
# ---------------------------------------------------------------------------
note '== full-device export integrity =='

# `*` puts the fault on EVERY read, which is how a reader that truncates or
# contradicts itself actually behaves. It also removes the shadow: with the
# fault on one read only, "the device changed between the two pre-write reads"
# would refuse first and the guard under test would never be reached.
new_case
program_run 'partialexport:*'
assert_rejects "an export that omits program memory" \
	"is not a complete full-device read"

new_case
program_run 'partialexport:1'
assert_rejects "an immediate pre-write export that omits program memory" \
	"is not a complete full-device read"

new_case
program_run 'conflict:*'
assert_rejects "an export that contradicts itself" "contradicts itself"

new_case
program_run 'halfword:*'
assert_rejects "an export with a truncated word" "without its high byte"

new_case
program_run 'badcal:0'
assert_rejects "a device whose calibration word is not RETLW" "is not RETLW k"

new_case
program_run 'noconfig:0'
assert_rejects "a baseline export with no CONFIG word" \
	"contains no complete CONFIG word"

# After the write the same observations are the RESULT, so they are published as
# named failures rather than aborting the readback that found them.
new_case
program_run 'partialexport:2'
assert_fail_result "a post-write export that omits program memory" \
	"post-program export is incomplete"
check "an incomplete post-write export still wrote exactly once" \
	"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

new_case
program_run 'conflict:2'
assert_fail_result "a post-write export that contradicts itself" \
	"post-program readback failed"

# ---------------------------------------------------------------------------
# 6. post-write damage detection -- exactly one write, published FAIL
# ---------------------------------------------------------------------------
note '== post-write verification =='

new_case
program_run 'eraseosccal:1'
assert_fail_result "an erased OSCCAL word" "OSCCAL word changed"
check "erased OSCCAL still wrote exactly once" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

new_case
program_run 'wrongosccal:1'
assert_fail_result "a rewritten OSCCAL value" "OSCCAL value changed"

new_case
program_run 'erasebg:1'
assert_fail_result "an erased bandgap field" "BG<1:0> changed"

new_case
program_run 'corrupt:1'
assert_fail_result "a corrupted program word" \
	"post-program word 0x0000 is 0x"

new_case
program_run 'noprogram:1'
assert_fail_result "a writer that silently programmed nothing" \
	"post-program word 0x0000 is 0x3FFF"

# The failure a per-image-address comparison cannot see at all. This writer
# skips its bulk erase, then writes every word the image supplies, correctly,
# and preserves both factory values. Everything the image asked for is on the
# device; what is also still on the device is the firmware that was there
# before, at an address the image does not supply and no image-driven
# comparison ever visits.
new_case
program_run 'noerase:1'
stale_word=$(device_field stale_word)
assert_fail_result "a writer that skipped its bulk erase" \
	"post-program word $stale_word is 0x1234"
check "the stale word is diagnosed as one the writer failed to erase" \
	"$([[ "$OUT" == *"The writer left this word behind"* ]] && echo 1 || echo 0)"
check "a no-erase overlay still wrote exactly once" \
	"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"
check "every other program word verified, so the count cannot mask the hole" \
	"$([ "$(result_field verified_program_words)" = 1022 ] \
		&& [ "$(result_field verified_config_word)" = True ] && echo 1 || echo 0)"
check "the trim survived, so the stale word is the only finding" \
	"$([ "$(result_field post_osccal_word)" = "$(result_field baseline_osccal_word)" ] \
		&& [ "$(result_field post_bg_bits)" = "$(result_field baseline_bg_bits)" ] && echo 1 || echo 0)"

# The other end of the image. A comparison that walked image addresses in order
# and stopped at the first mismatch would still catch a corruption at word 0;
# only one that reaches the LAST word the image represents catches this.
new_case
program_run 'corrupthigh:1'
corrupt_word=$(device_field corrupt_word)
assert_fail_result "a corruption at the last word the image represents" \
	"post-program word $corrupt_word is 0x"
check "the corruption is at the top of the image, not at word zero" \
	"$([ "$corrupt_word" != 0x0000 ] && echo 1 || echo 0)"
check "the count reports exactly one unverified word" \
	"$([ "$(result_field verified_program_words)" = 1022 ] && echo 1 || echo 0)"

new_case
program_run 'programfail:1'
assert_fail_result "a writer that reported failure" "reported exit 1"
check "a failed write is still read back" "$([ -s "$EVIDENCE/postread.hex" ] && echo 1 || echo 0)"

new_case
program_run 'newdevice:1'
assert_fail_result "a device whose identity changed" "device identity differs from baseline"

new_case
program_run 'readfail:2'
assert_fail_result "a failed post-write readback" "post-program readback failed"

new_case
program_run 'noexport:2'
assert_fail_result "a post-write read that exported nothing" "post-program readback failed"

# ---------------------------------------------------------------------------
# 7. interruption and read-only finalization
# ---------------------------------------------------------------------------
note '== interruption and finalization =='

# Kill the helper between the write and the readback: a real PENDING state.
make_pending() {
	new_case
	program_run 'killparent:program'
	check "an interrupted transaction leaves no result" \
		"$([ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
	check "an interrupted transaction leaves its reservation" \
		"$([ -s "$EVIDENCE/reservation.json" ] && echo 1 || echo 0)"
}

make_pending
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalization publishes a PASS" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "finalization records that it was a recovery" \
	"$([ "$(result_field finalization_mode)" = True ] && echo 1 || echo 0)"
check "finalization never wrote" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "a second finalization is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"already has a published result"* ]] && echo 1 || echo 0)"

make_pending
cp "$FAKE" "$CASE_DIR/other-ipecmd"
chmod 0755 "$CASE_DIR/other-ipecmd"
printf '\n# a different build\n' >> "$CASE_DIR/other-ipecmd"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$CASE_DIR/other-ipecmd"
check "finalization with a different programmer is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"not the one this transaction reserved"* ]] && echo 1 || echo 0)"
check "the refused finalization published no result" \
	"$([ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"

make_pending
run_helper 'version:6.25' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalization under a drifted tool version is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"this helper supports 6.20"* ]] && echo 1 || echo 0)"

make_pending
chmod 0600 "$EVIDENCE/image.hex"
printf ':00000001FF\n' >> "$EVIDENCE/image.hex"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalization with a tampered retained image is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"retained release image differs"* ]] && echo 1 || echo 0)"

make_pending
run_helper 'readfail:2' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "a failed recovery read leaves the transaction PENDING" \
	"$([ "$RC" -eq 2 ] && [ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
check "a failed recovery says the transaction stays PENDING" \
	"$([[ "$OUT" == *"stays PENDING"* ]] && echo 1 || echo 0)"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "recovery is retry-safe after a failed read" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "retried recovery still never wrote" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

# The other two boundaries: after the second read but before the reservation,
# and inside the post-write read.
new_case
program_run 'killparent:read1'
check "an interruption after the second read leaves no reservation" \
	"$([ ! -e "$EVIDENCE/reservation.json" ] && echo 1 || echo 0)"
assert_no_write "an interruption after the second read"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalizing an interruption before the reservation is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"no reservation to finalize"* ]] && echo 1 || echo 0)"

new_case
program_run 'killparent:read2'
check "an interruption inside the post-write read leaves PENDING" \
	"$([ -s "$EVIDENCE/reservation.json" ] && [ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
check "that interruption still wrote exactly once" \
	"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalization resolves an interruption inside the post-write read" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "resolving it never wrote" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

# An interruption inside FINALIZATION itself. The killed attempt has already
# created its own private export, so retry-safety here is what proves the
# per-attempt file naming works rather than merely existing.
make_pending
run_helper 'killparent:read2' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "an interrupted finalization publishes no result" \
	"$([ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
check "an interrupted finalization leaves its own attempt export" \
	"$([ -s "$EVIDENCE/finalize-00.hex" ] && echo 1 || echo 0)"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalization is retry-safe after an interruption" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "the retry used a private attempt export" \
	"$([ -s "$EVIDENCE/finalize-01.hex" ] && echo 1 || echo 0)"
check "neither finalization attempt wrote" "$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

# A PENDING directory reached through a symlink is not this transaction's
# directory, whatever it points at.
make_pending
ln -s "$EVIDENCE" "$CASE_DIR/evidence-link"
run_helper '' finalize --evidence-dir "$CASE_DIR/evidence-link" --ipecmd "$FAKE"
check "finalizing through a symlinked evidence path is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"evidence directory is a symbolic link"* ]] && echo 1 || echo 0)"
check "that refusal published no result" \
	"$([ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"

# An interruption BEFORE the reservation reserved nothing: there is no
# transaction to finalize, and finalization must say so rather than read a
# device it knows nothing about.
new_case
program_run 'killparent:read0'
check "an interruption before the reservation leaves none" \
	"$([ ! -e "$EVIDENCE/reservation.json" ] && echo 1 || echo 0)"
assert_no_write "an interruption before the reservation"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "finalizing an unreserved directory is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"no reservation to finalize"* ]] && echo 1 || echo 0)"

new_case
run_helper '' finalize --evidence-dir "$CASE_DIR/absent" --ipecmd "$FAKE"
check "finalizing a directory that does not exist is refused" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"evidence directory is unavailable"* ]] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# 8. durable, all-or-nothing evidence publication
# ---------------------------------------------------------------------------
note '== durable evidence publication =='

# Section 7 interrupts the transaction where a cable or a Ctrl-C would. This
# section interrupts it where only an operating system can: inside the four
# steps that turn bytes into a published record. Each one is failed and then
# killed at the same point, because "the syscall returned an error" and "the
# machine stopped here" leave different debris and both have to be recoverable.
publication_case() {
	new_case
	HOOK=1
	export "FLASH_HOOK_${1}_OP=$2" "FLASH_HOOK_${1}=$3"
	program_run ''
	hook_reset
}

# Whatever went wrong, what must be true afterwards is the same: no result.json
# under its final name, a reservation that still reads PENDING, and a read-only
# finalization that can still resolve it without touching the device again.
assert_recoverable_pending() {
	local label=$1 remnants=$2
	check "$label publishes nothing under the final result name" \
		"$([ ! -e "$EVIDENCE/result.json" ] && echo 1 || echo 0)"
	check "$label leaves the transaction PENDING" \
		"$([ -s "$EVIDENCE/reservation.json" ] && echo 1 || echo 0)"
	check "$label leaves $remnants inert publication remnant(s)" \
		"$([ "$(publication_remnants)" = "$remnants" ] && echo 1 || echo 0)"
	run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
	check "$label is resolved read-only by finalization" \
		"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
	check "$label never issued a second write" \
		"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"
}

# The directory ENTRY, not the directory. fsync on the new evidence directory
# does not flush the entry in its parent that names it, so a crash could leave a
# programmed device whose reservation directory never existed. It is proved
# here, before the device is touched at all.
publication_case FAIL fsync "evidence directory's parent"
check "an evidence directory entry that cannot be made durable refuses" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"could not flush the evidence directory's parent"* ]] && echo 1 || echo 0)"
assert_no_write "an undurable evidence directory entry"
check "it refused before any device read as well" \
	"$([ "$(reads)" = 0 ] && echo 1 || echo 0)"
check "the directory it could not make durable is not left behind" \
	"$([ ! -e "$EVIDENCE" ] && echo 1 || echo 0)"

publication_case FAIL write "programming result"
assert_recoverable_pending "a failed result write" 0

publication_case FAIL fsync "programming result"
assert_recoverable_pending "a failed result flush" 0

publication_case FAIL link "programming result"
assert_recoverable_pending "a failed final-name publication" 0

# The same three points, killed outright. The temporary file survives here,
# which is exactly why the final name is never the one being written into: a
# remnant nothing looks for is recoverable, a truncated result.json is not.
publication_case KILL write "programming result"
assert_recoverable_pending "a SIGKILL inside the result write" 1

publication_case KILL link "programming result"
assert_recoverable_pending "a SIGKILL before the final-name publication" 1

# Past the atomic install, the record exists and is complete. A later failure
# owes the operator that record, not a retry.
publication_case FAIL fsync "the evidence directory after programming result"
check "a result installed under its final name survives a failed directory flush" \
	"$([ -s "$EVIDENCE/result.json" ] && [ "$(result_field status)" = PASS ] \
		&& [ "$(result_field verified_program_words)" = 1023 ] && echo 1 || echo 0)"
published=$(sha256_of "$EVIDENCE/result.json")
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "that published result is immutable against a later finalization" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"already has a published result"* ]] \
		&& [ "$(sha256_of "$EVIDENCE/result.json")" = "$published" ] && echo 1 || echo 0)"
check "the refused finalization issued no write" \
	"$([ "$(writes)" = 1 ] && echo 1 || echo 0)"

publication_case KILL fsync "the evidence directory after programming result"
check "a SIGKILL after the atomic install still leaves one complete result" \
	"$([ -s "$EVIDENCE/result.json" ] && [ "$(result_field status)" = PASS ] \
		&& [ "$(result_field verified_program_words)" = 1023 ] \
		&& [ "$(result_field record_type)" = result ] && echo 1 || echo 0)"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "a killed publication that got as far as the final name is not retried" \
	"$([ "$RC" -eq 2 ] && [[ "$OUT" == *"already has a published result"* ]] && echo 1 || echo 0)"

# A remnant is not a result, whatever it is named after.
make_pending
: > "$EVIDENCE/result.json.0123456789abcdef.tmp"
run_helper '' finalize --evidence-dir "$EVIDENCE" --ipecmd "$FAKE"
check "a publication remnant is not mistaken for a completed result" \
	"$([ "$RC" -eq 0 ] && [[ "$OUT" == *"status=PASS"* ]] && echo 1 || echo 0)"
check "and the remnant did not become that result" \
	"$([ -s "$EVIDENCE/result.json" ] && [ "$(result_field status)" = PASS ] \
		&& [ "$(result_field verified_program_words)" = 1023 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
note "== PIC12F675 flashing-helper checks: $checks, failures: $failures =="
[ "$failures" -eq 0 ] || exit 1
