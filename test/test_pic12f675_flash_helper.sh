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
source_image=""
for candidate in "$ROOT/build_pic12f675/$IMAGE_NAME" \
		"$ROOT/release/v0.9.9/$IMAGE_NAME"; do
	if [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -s "$candidate" ]; then
		source_image=$candidate
		break
	fi
done
[ -n "$source_image" ] \
	|| { printf 'FAIL: no PIC12F675 release image available to exercise the helper\n' >&2; exit 1; }

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
}

# Run one helper invocation against this case's fake device.
run_helper() {
	local faults=$1
	shift
	set +e
	# The interruption cases kill the helper outright, and the shell announces a
	# signalled child on ITS stderr, not the child's. Send that notice to the
	# case log so a deliberate SIGKILL does not look like a broken gate.
	{
		FAKE_IPE_STATE="$DEVICE" FAKE_IPE_LOG="$ARGVLOG" \
		FAKE_IPE_WITNESS="$EVIDENCE/reservation.json" \
		FAKE_IPE_FAULTS="$faults" \
			python3 "$BUNDLE_HELPER" "$@" \
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

result_field() {
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
		"$EVIDENCE/result.json" "$1"
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
check "the write consumes the retained snapshot, not the caller's path" \
	"$([[ "${vectors[3]}" == *"-F$EVIDENCE/image.hex"* ]] && echo 1 || echo 0)"
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
check "result verifies every programmed byte" \
	"$([ "$(result_field programmed_image_bytes_verified)" -gt 0 ] && echo 1 || echo 0)"
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

# Running the helper from outside the bundle stays supported: only the copy
# that ships INSIDE a bundle is held to the bundle's own checksum.
new_case
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" --evidence-dir "$EVIDENCE"
BUNDLE_HELPER=$HELPER
run_helper '' program --image "$IMAGE" --ipecmd "$FAKE" --evidence-dir "$CASE_DIR/evidence2"
check "the tracked helper outside a bundle programs the same image" \
	"$([ "$RC" -eq 0 ] && echo 1 || echo 0)"

# Every shipping variant must be programmable by the tool that ships beside it.
# An output stage whose image the helper refuses would be a release-blocking
# defect that no other lane can see: the image gates check the BUILD, and this
# checks the one program allowed to write it.
note '== every shipping variant =='
for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
	variant_image=""
	for candidate in "$ROOT/build_pic12f675/bypass-pic12f675-$variant.hex" \
			"$ROOT/release/v0.9.9/bypass-pic12f675-$variant.hex"; do
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
assert_rejects "programmer-supplied power" "only the externally powered arrangement"

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
assert_fail_result "a corrupted program word" "post-program byte differs"

new_case
program_run 'noprogram:1'
assert_fail_result "a writer that silently programmed nothing" "post-program byte differs"

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
note "== PIC12F675 flashing-helper checks: $checks, failures: $failures =="
[ "$failures" -eq 0 ] || exit 1
