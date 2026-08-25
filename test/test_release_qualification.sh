#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-release-qualification.sh"
RENDER="$ROOT/scripts/release-documentation.sh"
PIC12F675_FEASIBILITY="$ROOT/docs/pic12f675_feasibility.md"
DESIGN_DOCUMENTATION="$ROOT/DESIGN_DOCUMENTATION.adoc"
PROJECT_README="$ROOT/README.md"
RELEASE_README="$ROOT/release/README.md"
TEST_README="$ROOT/test/README.md"
MATRIX_TOOL="$ROOT/test/pic/pic12f675_matrix_evidence.py"
RELEASE=${RELEASE:-$ROOT/scripts/make-release.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-qualification.XXXXXX")
release="$work/release"
matrix_build="$work/pic12f675-matrix"
sha=0123456789abcdef0123456789abcdef01234567
version=v99.0.0
checks=0
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -r "$RENDER" ] || fail "release documentation renderer is missing"
[ -r "$MATRIX_TOOL" ] || fail "PIC12F675 matrix evidence helper is missing"
[ -r "$PIC12F675_FEASIBILITY" ] \
	|| fail "PIC12F675 feasibility document is missing"
[ -r "$DESIGN_DOCUMENTATION" ] \
	|| fail "design documentation is missing"
for document in "$PROJECT_README" "$RELEASE_README" "$TEST_README"; do
	[ -r "$document" ] || fail "release-facing documentation is missing: $document"
done
# shellcheck source=../scripts/release-documentation.sh
source "$RENDER"
for function in release_validate_current_documentation \
		release_validate_staged_documentation \
		release_validate_hardware_claims \
		release_validate_pic12f675_flashing_helper \
		release_render_scope release_render_validation \
		release_render_pic_toolchain_rows release_render_pic12f675_flashing \
		release_render_flashing \
		release_render_reproduction_commands \
		release_render_commit_message; do
	declare -F "$function" >/dev/null \
		|| fail "release documentation renderer omitted $function"
done
checks=$((checks + 1))

# The feasibility assessment preserves prospective design history, but its
# current disposition must agree with the release contract and keep silicon-only
# residual risk explicit. Pin only those semantics, not incidental prose.
if ! current_pic12f675_status=$(awk '
	$0 == "<!-- current-status:start -->" {
		starts++
		if (starts != 1 || current || NR != 3) bad=1
		current=1
		next
	}
	$0 == "<!-- current-status:end -->" {
		ends++
		if (ends != 1 || !current) bad=1
		current=0
		next
	}
	current { print }
	END { exit !(starts == 1 && ends == 1 && !current && !bad) }
' "$PIC12F675_FEASIBILITY"); then
	fail "PIC12F675 feasibility document must have one opening current-status block"
fi
[ -n "$current_pic12f675_status" ] \
	|| fail "PIC12F675 feasibility document has no bounded current-status section"
current_pic12f675_status_one_line=$(printf '%s\n' "$current_pic12f675_status" \
	| tr '\n' ' ' | tr -s ' ')
for required in \
		'**Current status (v0.9.10;' \
		'PIC12F675 is **release-supported from `v0.9.9`**' \
		'included in the default `all` goal, both CI aggregates' \
		'21-image release set, the 18-combination release soak, and the 34-file retained evidence inventory' \
		'Section 8 items 1, 2, 8, and 9 remain explicitly deferred to the `1.x.y` hardware-validation pass' \
		'provides no real-programmer factory-trim preservation guarantee'; do
	grep -Fq "$required" <<<"$current_pic12f675_status_one_line" \
		|| fail "PIC12F675 current-status section omits release semantics: $required"
done
if grep -Eiq '(PIC12F675|the part|this part) (is|remains) (intentionally )?(not release-supported|(absent from|excluded from|not included in) (the )?(default `all` goal|CI|release integration|(canonical )?([0-9]+-image )?release set))|(^|[.!?] )((the|this|a) )?(workflow|programmer|pk2cmd|ipecmd) (preserves|guarantees|ensures)([ .]|$)|(^|[.!?] )(factory trim|factory values|OSCCAL|BG) (is|are) preserved([ .]|$)' \
		<<<"$current_pic12f675_status_one_line"; then
	fail "PIC12F675 current-status section contradicts its release-supported disposition"
fi
for required in \
		'| Implemented integration | default `all`, both CI aggregates' \
		'**Status 2026-08-13 (v0.9.9 disposition).**' \
		'**Current implementation status (v0.9.10):**' \
		'## 9. Historical effort and suggested sequencing' \
		'## 11. Historical documentation plan'; do
	grep -Fq "$required" "$PIC12F675_FEASIBILITY" \
		|| fail "PIC12F675 feasibility document omits a current/historical boundary: $required"
done
checks=$((checks + 1))

# Pin the safety-relevant multi-MCU distinctions: PIC12F675's longer sample
# period, all three polled PIC implementations, and the fixed low BOD threshold.
# Normalize wrapping so AsciiDoc line breaks remain editorial rather than API.
design_contract=$(tr '\n' ' ' < "$DESIGN_DOCUMENTATION" | tr -s ' ')
for required in \
		'Six targets use a nominal 1ms timer-derived sample cadence. PIC12F675 uses 1.024ms' \
		'all three PIC implementations poll their timer flags' \
		'the 1ms targets span roughly 0.909-1.111ms per sample and PIC12F675 spans roughly 0.931-1.138ms' \
		'8 * 1.138ms = 9.11ms on PIC12F675' \
		'the PIC12F675 counterpart is 7 * 0.931ms = 6.52ms' \
		'33ms/38ms/45ms for PIC10F32x and approximately 33.8ms/38.8ms/45.8ms for PIC12F675' \
		'latched `T0IF` supplies only the first of four required 256us rollover observations' \
		'PIC12F675:: BOD is enabled (`BOREN=ON`) at a fixed 2.025-2.175v trip range' \
		'this part has no `BORV` selection' \
		'It therefore cannot enforce the >4v peripheral-safe floor either' \
		'External supply supervision is required' \
		'seven MCU release targets across four core generations' \
		'Six targets use the modular architecture through four shell source files' \
		'all three polled PIC implementations pause sampling during a blocking output actuation'; do
	grep -Fq "$required" <<<"$design_contract" \
		|| fail "design documentation omits PIC12F675 safety/topology semantics: $required"
done
if grep -Eiq 'All targets use a nominal 1ms timer-derived sample cadence|while both PIC implementations poll|On both PIC parts, the footswitch loop|For both polled PIC implementations|six MCU release targets across three core generations|both polled PIC implementations qualify press timing|PIC12F675[^.]*T0IF[^.]*(next sample|post-block sample)[^.]*immediate|PIC12F675[^.]*immediate[^.]*T0IF' \
		<<<"$design_contract"; then
	fail "design documentation still describes the pre-PIC12F675 timing/topology"
fi
checks=$((checks + 1))

# Current reader-facing inventories must agree with the canonical seven-part,
# three-PIC, 21-image, 18-soak, and 34-evidence contract while preserving the
# explicitly historical six-target releases.
project_contract=$(tr '\n' ' ' < "$PROJECT_README" | tr -s ' ')
release_contract=$(tr '\n' ' ' < "$RELEASE_README" | tr -s ' ')
test_contract=$(tr '\n' ' ' < "$TEST_README" | tr -s ' ')
for required in \
		'seven release parts across four microcontroller core generations' \
		'PIC10F322, PIC10F320, and PIC12F675 provide functional, fault-injection' \
		'PIC12F675 is release-supported from `v0.9.9`, raising the canonical set to 21 images'; do
	grep -Fq "$required" <<<"$project_contract" \
		|| fail "top-level README omits current release scope: $required"
done
for required in \
		'Unified releases `v0.9.6`–`v0.9.8` shipped the six pre-PIC12F675 targets only' \
		'From `v0.9.9`, every combination exists, so a release is exactly 7 x 3 = 21 images' \
		'six-target, 18-image set and no PIC12F675 build directory' \
		'### Unified releases (v0.9.9 or later)' \
		'`build_pic10f320/`, and `build_pic12f675/`' \
		'make pic10f322 && make pic10f320-variants && make pic12f675'; do
	grep -Fq "$required" <<<"$release_contract" \
		|| fail "release README omits current/historical release scope: $required"
done
for required in \
		'`pic10f320-test-stack-bound`, `pic12f675-test-stack-bound`' \
		'exact canonical 34-file evidence set' \
		'each of 18 release soak combinations' \
		'historical 28-file/15-soak boundary for v0.9.6-v0.9.8' \
		'36 PIC10F322, 75 PIC10F320, and 156 PIC12F675 checks' \
		'## Known gaps (PIC — hardware-bench only)' \
		'### PIC10F32x hardware gaps' \
		'### PIC12F675 hardware gaps'; do
	grep -Fq "$required" <<<"$test_contract" \
		|| fail "test README omits current PIC/release scope: $required"
done
checks=$((checks + 1))

for wiring in \
	'source "$REPO_ROOT/scripts/release-documentation.sh"' \
	'release_validate_current_documentation "$REPO_ROOT" "$VERSION"' \
	$'\trelease_render_scope' \
	$'\trelease_render_validation "$hours"' \
	$'\trelease_render_pic_toolchain_rows "$PIC_CC" "$TC_XC8_322"' \
	$'\t\t"$PIC10F320_CC" "$TC_XC8_320" "$PIC_DFP" "$PIC10F320_DFP"' \
	$'\trelease_render_flashing "$WORK/flashcmds.txt" "$VERSION"' \
	$'\trelease_render_reproduction_commands "$VERSION" "$RELEASE_IMAGE_DIRS"' \
	$'\t\t"$AVR_BUILD_DIR" "$XT_BUILD_DIR" "$PIC10F322_BUILD_DIR"' \
	$'\t\t"$PIC10F320_BUILD_DIR" "$PIC12F675_BUILD_DIR"' \
	$'\t\t"$PIC_CC" "$PIC_DFP" "$PIC10F320_CC" "$PIC10F320_DFP"' \
	'release_render_commit_message "$VERSION" "$RELEASE_MODE" "$GIT_SHORT"' \
	$'\t"${#IMAGES[@]}" "$hours" > "$OUTPUT_DIR/commit_msg.txt"'; do
	grep -Fq "$wiring" "$RELEASE" \
		|| fail "release producer does not consume rendered documentation section: $wiring"
done
checks=$((checks + 1))

# --no-print-directory is required on every capture here, and -s does not imply
# it: Make enables -w in a sub-make and propagates a literal w through
# MAKEFLAGS, where it OVERRIDES -s. `make release` reaches this gate through
# such a sub-make -- make-release.sh holds the worktree lock, so the
# serialization wrapper that would supply the flag never runs -- and the
# directory banner would then be parsed as the first name in each set.
read -r -a soak_names \
	<<<"$(make -s --no-print-directory -C "$ROOT" CC=: print-RELEASE_SOAK_NAMES)"
read -r -a evidence_names \
	<<<"$(make -s --no-print-directory -C "$ROOT" CC=: print-RELEASE_EVIDENCE_FILES)"
fw_base=$(make -s --no-print-directory -C "$ROOT" CC=: print-FW_BASE)
pic12f675_tag=$(make -s --no-print-directory -C "$ROOT" CC=: print-PIC12F675_TAG)
read -r -a pic12f675_variants \
	<<<"$(make -s --no-print-directory -C "$ROOT" CC=: print-CLASSIC_VARIANTS_SUPPORTED)"

reset_fixture() {
	local mode=${1:-production}
	local duration=${2:-86400000}
	local liveness=${3:-60000}
	local dirty=${4:-0}
	local expected_checks=$((duration / liveness)) name file variant stem
	local matrix_record matrix_digest
	rm -rf "$release" "$matrix_build"
	mkdir -p "$release/evidence" "$matrix_build/simcal"
	for file in "${evidence_names[@]}"; do
		printf 'retained evidence: %s\n' "$file" > "$release/evidence/$file"
	done
	for variant in "${pic12f675_variants[@]}"; do
		stem="$fw_base-$pic12f675_tag-$variant"
		printf 'shipping fixture: %s\n' "$variant" > "$matrix_build/$stem.hex"
		printf 'assembly fixture: %s\n' "$variant" > "$matrix_build/$stem.s"
		printf 'symbol fixture: %s\n' "$variant" > "$matrix_build/$stem.sym"
		printf 'simcal fixture: %s\n' "$variant" \
			> "$matrix_build/simcal/${stem}_simcal.hex"
	done
	python3 "$MATRIX_TOOL" record --build-dir "$matrix_build" \
		--fw-base "$fw_base" --tag "$pic12f675_tag" >/dev/null
	matrix_record=$(python3 "$MATRIX_TOOL" verify --build-dir "$matrix_build" \
		--fw-base "$fw_base" --tag "$pic12f675_tag")
	cp -p -- "$matrix_build/.pic12f675-qualified-matrix.json" \
		"$release/evidence/pic12f675-qualified-matrix.json"
	for variant in "${pic12f675_variants[@]}"; do
		stem="$fw_base-$pic12f675_tag-$variant"
		cp -p -- "$matrix_build/$stem.hex" "$release/"
	done
	(
		cd "$release"
		sha256sum -- "$fw_base-$pic12f675_tag-"*.hex > SHA256SUMS
	)
	matrix_digest=$(sha256sum -- \
		"$release/evidence/pic12f675-qualified-matrix.json")
	matrix_digest=${matrix_digest%% *}
	{
		printf '=== PIC12F675 retained matrix qualified: %s ===\n' "$matrix_record"
		printf '=== all PIC12F675 pre-hardware checks complete: %s ===\n' "$matrix_record"
		for variant in "${pic12f675_variants[@]}"; do
			printf '=== PIC12F675 target fault/lock-step/I-O PASS (variant %s): %s ===\n' \
				"$variant" "$matrix_record"
		done
		printf '=== PIC12F675 target fault/lock-step/I-O validated for all variants: %s ===\n' \
			"$matrix_record"
	} > "$release/evidence/pic12f675-qualification.log"
	for name in "${soak_names[@]}"; do
		cat > "$release/evidence/soak-$name.log" <<EOF
SOAK START: synthetic qualification fixture
SOAK PASS: $duration ms (fixture) simulated.
SOAK_RESULT format=1 status=pass combination=$name duration_ms=$duration liveness_interval_ms=$liveness checks=$expected_checks failures=0 watchdog_failures=0 liveness_failures=0
EOF
	done
	cat > "$release/QUALIFICATION" <<EOF
format=2
version=$version
release_mode=$mode
source_commit=$sha
source_dirty=$dirty
soak_duration_ms=$duration
soak_liveness_interval_ms=$liveness
soak_combination_count=${#soak_names[@]}
pic12f675_matrix_sha256=$matrix_digest
EOF
	{
		printf '# Firmware release %s\n\n' "$version"
		[ "$mode" != dry-run ] \
			|| printf '> **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.\n\n'
		printf -- '- **Release mode:** %s\n' "$mode"
		printf -- '- **Source commit:** `%s`\n' "$sha"
		printf -- '- **Soak duration per combination:** %s ms\n' "$duration"
		printf -- '- **Soak combinations:** %s\n' "${#soak_names[@]}"
		printf -- '- **PIC12F675 qualified matrix:** `evidence/pic12f675-qualified-matrix.json` (SHA-256 `%s`)\n' \
			"$matrix_digest"
	} > "$release/MANIFEST.md"
}

refresh_matrix_digest() {
	local old_digest new_digest
	old_digest=$(awk -F= '$1 == "pic12f675_matrix_sha256" { print $2 }' \
		"$release/QUALIFICATION")
	new_digest=$(sha256sum -- "$release/evidence/pic12f675-qualified-matrix.json")
	new_digest=${new_digest%% *}
	sed -i "s/$old_digest/$new_digest/g" \
		"$release/QUALIFICATION" "$release/MANIFEST.md"
}

expect_pass() {
	local label=$1
	shift
	"$VERIFY" "$@" "$release" "$version" >/dev/null \
		|| fail "$label: valid qualification was rejected"
	checks=$((checks + 1))
}

expect_fail() {
	local label=$1 expected=$2
	shift 2
	local output
	if output=$("$VERIFY" "$@" "$release" "$version" 2>&1); then
		fail "$label: invalid qualification was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

reset_fixture
expect_pass "complete production qualification"

# The verifier uses Make for canonical inventory and Python for the retained
# matrix, but needs no target compiler. The Makefile probes avr-gcc at parse time
# to locate analyzer headers; on a host without avr-gcc that once leaked
# "command not found" onto this metadata-only path. The verifier passes CC=: to
# every query, so prove with a tripwire avr-gcc that a valid qualification still
# passes with no compiler diagnostics on stderr.
# This reproduces the real trigger because the Makefile's `CC = avr-gcc`
# overrides the environment -- only the command-line CC=: bypasses the shim.
tripwire_bin="$work/tripwire-bin"
mkdir -p "$tripwire_bin"
cat > "$tripwire_bin/avr-gcc" <<'SH'
#!/bin/sh
echo "TRIPWIRE: avr-gcc must not be invoked by the metadata-only verifier" >&2
exit 1
SH
chmod +x "$tripwire_bin/avr-gcc"
reset_fixture
if ! tripwire_err=$(PATH="$tripwire_bin:$PATH" "$VERIFY" "$release" "$version" \
		2>&1 >/dev/null); then
	fail "tool-independent verification failed when avr-gcc was shadowed by a tripwire"
fi
case "$tripwire_err" in
	*TRIPWIRE*|*"command not found"*|*"No such file"*)
		fail "verifier invoked the AVR compiler on the metadata-only path: $tripwire_err" ;;
esac
[ -z "$tripwire_err" ] \
	|| fail "verifier emitted unexpected diagnostics on the tool-independent path: $tripwire_err"
checks=$((checks + 1))

if output=$("$VERIFY" "$release" v99.0.0.rc1 2>&1); then
	fail "qualification verifier accepted a version the release workflow does not trigger"
fi
[[ "$output" == *"invalid expected release version"* ]] \
	|| fail "invalid expected version failed for the wrong reason: $output"
checks=$((checks + 1))

reset_fixture
rm "$release/QUALIFICATION"
expect_fail "missing qualification" "QUALIFICATION is missing"

reset_fixture
mv "$release/QUALIFICATION" "$release/real-qualification"
ln -s real-qualification "$release/QUALIFICATION"
expect_fail "symlink qualification" "QUALIFICATION is missing"

reset_fixture
printf 'extra=value\n' >> "$release/QUALIFICATION"
expect_fail "unknown qualification key" "unknown QUALIFICATION key"

reset_fixture
printf 'format=2\n' >> "$release/QUALIFICATION"
expect_fail "duplicate qualification key" "duplicate QUALIFICATION key"

reset_fixture
sed -i 's/^format=2$/format=1/' "$release/QUALIFICATION"
expect_fail "obsolete qualification format" "unsupported QUALIFICATION format"

reset_fixture
sed -i 's/^version=.*/version=v99.0.1/' "$release/QUALIFICATION"
expect_fail "wrong qualification version" "does not match"

reset_fixture dry-run 60000 60000 1
expect_fail "dry run rejected by publication verifier" "dry-run qualification is not publishable"
expect_pass "dry run accepted only for producer self-check" --allow-dry-run

reset_fixture production 86400000 60000 1
expect_fail "dirty production qualification" "source_dirty=0"

reset_fixture production 60000 60000 0
expect_fail "short production soak" "below 86400000"

reset_fixture
sed -i 's/^soak_duration_ms=.*/soak_duration_ms=4294967295/' "$release/QUALIFICATION"
expect_fail "overflowing soak duration" "exceeds 4294967294"

reset_fixture
sed -i 's/^soak_combination_count=.*/soak_combination_count=11/' "$release/QUALIFICATION"
expect_fail "wrong soak count" "does not match the canonical set"

reset_fixture
rm "$release/evidence/${evidence_names[0]}"
expect_fail "missing evidence file" "does not exactly match RELEASE_EVIDENCE_FILES"

reset_fixture
printf 'extra\n' > "$release/evidence/.hidden"
expect_fail "hidden extra evidence" "invalid name"

reset_fixture
: > "$release/evidence/${evidence_names[0]}"
expect_fail "empty evidence file" "empty or not regular"

reset_fixture
rm "$release/evidence/pic12f675-qualified-matrix.json"
expect_fail "missing PIC12F675 matrix evidence" "does not exactly match RELEASE_EVIDENCE_FILES"

reset_fixture
mv "$release/evidence/pic12f675-qualified-matrix.json" \
	"$release/evidence/real-pic12f675-qualified-matrix.json"
ln -s real-pic12f675-qualified-matrix.json \
	"$release/evidence/pic12f675-qualified-matrix.json"
expect_fail "symlink PIC12F675 matrix evidence" "empty or not regular"

reset_fixture
sed -i 's/^pic12f675_matrix_sha256=.*/pic12f675_matrix_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
	"$release/QUALIFICATION"
expect_fail "wrong qualified-matrix digest" "matrix digest does not match QUALIFICATION"

reset_fixture
sed -i 's/(SHA-256 `[0-9a-f]\{64\}`)/(SHA-256 `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`)/' \
	"$release/MANIFEST.md"
expect_fail "wrong manifest matrix digest" "MANIFEST.md PIC12F675 matrix digest"

reset_fixture
sed -i 's/{"device"/{"device":"PIC12F675","device"/' \
	"$release/evidence/pic12f675-qualified-matrix.json"
refresh_matrix_digest
expect_fail "duplicate matrix JSON key" "duplicate JSON key"

reset_fixture
printf 'not-json\n' > "$release/evidence/pic12f675-qualified-matrix.json"
refresh_matrix_digest
expect_fail "malformed matrix JSON" "cannot read strict matrix evidence"

reset_fixture
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); del d["entries"]["assembly_cd4053_simple"]; open(p,"w").write(json.dumps(d,sort_keys=True,separators=(",",":"))+"\n")' \
	"$release/evidence/pic12f675-qualified-matrix.json"
refresh_matrix_digest
expect_fail "incomplete matrix artifact inventory" "artifact inventory is not exact"

reset_fixture
printf 'changed released image\n' \
	> "$release/$fw_base-$pic12f675_tag-cd4053_simple.hex"
expect_fail "released image differs from qualified matrix" \
	"released image does not match qualified matrix"

reset_fixture
sed -i "/  $fw_base-$pic12f675_tag-cd4053_simple.hex$/s/^[0-9a-f]\{64\}/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" \
	"$release/SHA256SUMS"
expect_fail "release checksum differs from qualified matrix" \
	"SHA256SUMS does not match qualified matrix"

reset_fixture
sed -i '/all PIC12F675 pre-hardware checks complete/s/shipping_cd4053_simple=[0-9a-f]\{64\}/shipping_cd4053_simple=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
	"$release/evidence/pic12f675-qualification.log"
expect_fail "split PIC12F675 matrix identities" "one exact matrix-bound PASS"

reset_fixture
sed -i '/all PIC12F675 pre-hardware checks complete/d' \
	"$release/evidence/pic12f675-qualification.log"
expect_fail "missing PIC12F675 pre-hardware PASS" "one exact matrix-bound PASS"

reset_fixture
sed -i '/retained matrix qualified/d' \
	"$release/evidence/pic12f675-qualification.log"
expect_fail "missing PIC12F675 qualifier PASS" "one exact matrix-bound PASS"

reset_fixture
sed -i '/PASS (variant cd4053_with_mute)/d' \
	"$release/evidence/pic12f675-qualification.log"
expect_fail "missing PIC12F675 target-variant PASS" "one exact matrix-bound PASS"

reset_fixture
sed -i '/validated for all variants/d' \
	"$release/evidence/pic12f675-qualification.log"
expect_fail "missing PIC12F675 all-variant PASS" "one exact matrix-bound PASS"

reset_fixture
matrix_line=$(grep 'retained matrix qualified' \
	"$release/evidence/pic12f675-qualification.log")
printf '%s\n' "$matrix_line" >> "$release/evidence/pic12f675-qualification.log"
expect_fail "duplicate PIC12F675 matrix record" "one exact matrix-bound PASS"

reset_fixture
matrix_line=$(grep 'retained matrix qualified' \
	"$release/evidence/pic12f675-qualification.log")
printf '%s conflict\n' "$matrix_line" >> "$release/evidence/pic12f675-qualification.log"
expect_fail "conflicting extra PIC12F675 matrix record" \
	"unexpected or duplicate matrix records"

reset_fixture
first_soak=${soak_names[0]}
sed -i '/^SOAK_RESULT /d' "$release/evidence/soak-$first_soak.log"
expect_fail "missing machine result" "exactly one SOAK_RESULT"

reset_fixture
record=$(grep '^SOAK_RESULT ' "$release/evidence/soak-$first_soak.log")
printf '%s\n' "$record" >> "$release/evidence/soak-$first_soak.log"
expect_fail "duplicate machine result" "exactly one SOAK_RESULT"

reset_fixture
sed -i 's/ combination=[^ ]*/ combination=wrong/' \
	"$release/evidence/soak-$first_soak.log"
expect_fail "wrong result combination" "invalid SOAK_RESULT"

reset_fixture
sed -i 's/ checks=1440 / checks=0 /' "$release/evidence/soak-$first_soak.log"
expect_fail "zero result checks" "invalid SOAK_RESULT"

reset_fixture
sed -i 's/ failures=0 / failures=1 /' "$release/evidence/soak-$first_soak.log"
expect_fail "nonzero result failures" "invalid SOAK_RESULT"

reset_fixture
sed -i 's/^SOAK PASS: 86400000 ms /SOAK PASS: 60000 ms /' \
	"$release/evidence/soak-$first_soak.log"
expect_fail "wrong human-summary duration" "exact-duration SOAK PASS"

reset_fixture
printf 'SOAK FAIL: injected contradiction\n' >> "$release/evidence/soak-$first_soak.log"
expect_fail "contradictory fail summary" "also contains a SOAK FAIL"

reset_fixture
sed -i 's/^- \*\*Release mode:\*\* production/- **Release mode:** dry-run/' \
	"$release/MANIFEST.md"
expect_fail "manifest mode mismatch" "release mode does not match"

reset_fixture
sed -i "s/$sha/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" "$release/MANIFEST.md"
expect_fail "manifest source mismatch" "source commit does not match"

reset_fixture
sed -i 's/^- \*\*Soak duration per combination:\*\*.*/- **Soak duration per combination:** 60000 ms/' \
	"$release/MANIFEST.md"
expect_fail "manifest soak-duration mismatch" "soak duration does not match"

reset_fixture
sed -i 's/^- \*\*Soak combinations:\*\*.*/- **Soak combinations:** 11/' \
	"$release/MANIFEST.md"
expect_fail "manifest soak-count mismatch" "soak count does not match"

[ "${#soak_names[@]}" -eq 18 ] \
	|| fail "canonical release soak set has ${#soak_names[@]} entries, expected 18"
overridden=$(make -s --no-print-directory -C "$ROOT" \
	RELEASE_SOAK_NAMES=bad print-RELEASE_SOAK_NAMES)
[ "$overridden" = "${soak_names[*]}" ] \
	|| fail "command-line override changed canonical RELEASE_SOAK_NAMES"
for required in attiny85_cd4053_simple attiny45_cd4053_simple \
		attiny202_tq2_l2_5v_relay \
		pic10f322_tq2_l2_5v_relay pic10f320_tq2_l2_5v_relay \
		pic12f675_tq2_l2_5v_relay; do
	[[ " ${soak_names[*]} " == *" $required "* ]] \
		|| fail "canonical release soak set is missing $required"
done
checks=$((checks + 1))

[ "${#evidence_names[@]}" -eq 34 ] \
	|| fail "canonical release evidence set has ${#evidence_names[@]} entries, expected 34"
for required in pic12f675-qualification.log pic12f675-qualified-matrix.json; do
	[[ " ${evidence_names[*]} " == *" $required "* ]] \
		|| fail "canonical release evidence set is missing $required"
done
for retired in pic12f675-test.log pic12f675-test-target-variants.log; do
	[[ " ${evidence_names[*]} " != *" $retired "* ]] \
		|| fail "canonical release evidence set still retains split PIC12F675 log $retired"
done
overridden=$(make -s --no-print-directory -C "$ROOT" \
	RELEASE_EVIDENCE_FILES=bad print-RELEASE_EVIDENCE_FILES)
[ "$overridden" = "${evidence_names[*]}" ] \
	|| fail "command-line override changed canonical RELEASE_EVIDENCE_FILES"
checks=$((checks + 1))

for wiring in \
	'AVR_SOAK_COMBINATION_NAME="$name"' \
	'PIC10F322_SOAK_COMBINATION_NAME="$name"' \
	'PIC10F320_SOAK_COMBINATION_NAME="$name"' \
	'PIC12F675_SOAK_COMBINATION_NAME="$name"' \
	'ATTINY202_SOAK_COMBINATION_NAME=%q'; do
	grep -Fq "$wiring" "$RELEASE" \
		|| fail "release producer is missing soak identity wiring: $wiring"
done
grep -Fq 'scripts/verify-release-qualification.sh "${qualification_args[@]}" "$OUTPUT_DIR" "$VERSION"' \
	"$RELEASE" \
	|| fail "release producer does not self-verify staged qualification"
# MANIFEST.md is published verbatim as the GitHub Release body, where a
# repo-relative link does not resolve. Pin all three properties of the fix --
# absolute base, tag-pinned path, and the absence of the old relative form --
# rather than one exact source line, so reformatting the generator cannot
# silently drop the assertion.
grep -Eq '^REPO_URL=https://github\.com/matt-garman/mcu-bypass-firmware$' \
	"$RELEASE" \
	|| fail "release manifest link base REPO_URL is not the canonical absolute project URL"
grep -Fq 'Full detail: [docs/pic10f320_special_case.md](%s/blob/%s/docs/pic10f320_special_case.md)' \
	"$RELEASE" \
	|| fail "release manifest special-case link is not pinned to its version tag"
grep -Fq '"$REPO_URL" "$VERSION"' \
	"$RELEASE" \
	|| fail "release manifest special-case link does not interpolate REPO_URL and VERSION"
! grep -Fq '](../../docs/pic10f320_special_case.md)' "$RELEASE" \
	|| fail "release manifest special-case link regressed to a repo-relative path"
grep -Fq 'scripts/verify-release-qualification.sh "$dir" "$tag"' \
	"$ROOT/.github/workflows/release.yml" \
	|| fail "tag workflow does not verify committed release qualification"
grep -Fq '"$dir/QUALIFICATION"' "$ROOT/.github/workflows/release.yml" \
	|| fail "tag workflow does not retain QUALIFICATION for publication"
grep -Fq 'a staged PIC image differs from the image exercised by the soak' \
	"$RELEASE" \
	|| fail "release producer does not bind staged PIC images to soak inputs"
grep -Fq "a staged PIC12F675 image differs from the one its gates validated and its soak's calibration preimage" \
	"$RELEASE" \
	|| fail "release producer does not bind staged PIC12F675 images to their gates and simcal soak"
grep -Fq 'a staged ATtiny202 image differs from the image exercised by its gates and soak' \
	"$RELEASE" \
	|| fail "release producer does not bind staged ATtiny202 images to soak inputs"
grep -Fq 'a staged classic AVR image differs from the final HEX regenerated from its validated ELF' \
	"$RELEASE" \
	|| fail "release producer does not bind staged classic AVR images to validated ELFs"
for wiring in \
	'make pic12f675-test pic12f675-test-target-variants \' \
	'python3 "$PIC12F675_MATRIX_EVIDENCE" verify-release \' \
	'make --old-file=_pic12f675-build-soak "$bin"'; do
	grep -Fq "$wiring" "$RELEASE" \
		|| fail "release producer omits one-matrix PIC12F675 wiring: $wiring"
done
for retired in '$EVID/pic12f675-test.log' \
		'$EVID/pic12f675-test-target-variants.log'; do
	! grep -Fq "$retired" "$RELEASE" \
		|| fail "release producer still writes split PIC12F675 evidence: $retired"
done
checks=$((checks + 1))

# Render and execute the generated reproduction recipe with paths containing
# spaces. This exercises the exact public commands without running a release or
# allowing the recipe to invoke Git, Make, or the real image verifier.
render_bin="$work/render-bin"
render_fixture="$work/render-fixture"
render_log="$work/render.log"
reproduction="$work/reproduction.sh"
selected_pic_cc="$work/selected PIC XC8/xc8-cc"
selected_pic_dfp="$work/selected PIC DFP"
selected_pic320_cc="$work/selected PIC10F320 XC8/xc8-cc"
selected_pic320_dfp="$work/selected PIC10F320 DFP"
avr_build_dir=custom/build_avr_classic
xt_build_dir=custom/build_avr_xt
pic10f322_build_dir=custom/build_pic10f322
pic10f320_build_dir=custom/build_pic10f320
pic12f675_build_dir=custom/build_pic12f675
mkdir -p "$render_bin" "$render_fixture/scripts"
cat > "$render_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GIT_SAFETY_LOG:-}" ]; then
	printf 'git' >> "$GIT_SAFETY_LOG"
	printf '\t%s' "$@" >> "$GIT_SAFETY_LOG"
	printf '\n' >> "$GIT_SAFETY_LOG"
	if [ "$#" -eq 2 ] && [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then
		[ "${GIT_COMMAND_FAIL:-}" != root ] || exit 92
		printf '%s\n' "$PWD"
		exit 0
	fi
	if [ "$#" -eq 5 ] && [ "$1" = -C ] && [ "$3" = rev-parse ] \
			&& [ "$4" = --verify ]; then
		if [ "${GIT_COMMAND_FAIL:-}" = head ] && [ "$5" = 'HEAD^{commit}' ]; then
			exit 92
		fi
		if [ "${GIT_COMMAND_FAIL:-}" = tag ] && [ "$5" != 'HEAD^{commit}' ]; then
			exit 92
		fi
		if [ "${GIT_TAG_MISMATCH:-0}" -eq 1 ] && [ "$5" != 'HEAD^{commit}' ]; then
			printf '%s\n' ffffffffffffffffffffffffffffffffffffffff
			exit 0
		fi
		printf '%s\n' 0123456789abcdef0123456789abcdef01234567
		exit 0
	fi
	if [ "$#" -eq 5 ] && [ "$1" = -C ] && [ "$3" = status ]; then
		[ "${GIT_COMMAND_FAIL:-}" != status ] || exit 92
		[ "${GIT_WORKTREE_DIRTY:-0}" -eq 0 ] \
			|| printf '%s\n' ' M src/changed.c'
		exit 0
	fi
	exit 91
fi
printf 'git' >> "${RENDER_LOG:?}"
printf '\t%s' "$@" >> "$RENDER_LOG"
printf '\n' >> "$RENDER_LOG"
EOF
cat > "$render_bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'make' >> "${RENDER_LOG:?}"
printf '\t%s' "$@" >> "$RENDER_LOG"
printf '\n' >> "$RENDER_LOG"
if [ "${TEST_PREFLIGHT_FAIL:-0}" -eq 1 ]; then
	for argument in "$@"; do
		[ "$argument" != pic12f675-preflight ] || exit 97
	done
fi
EOF
cat > "$render_fixture/scripts/verify-release-images.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify' >> "${RENDER_LOG:?}"
printf '\t%s' "$@" >> "$RENDER_LOG"
printf '\n' >> "$RENDER_LOG"
EOF
chmod 750 "$render_bin/git" "$render_bin/make" \
	"$render_fixture/scripts/verify-release-images.sh"

release_dirs_text="$avr_build_dir $xt_build_dir $pic10f322_build_dir $pic10f320_build_dir $pic12f675_build_dir"
release_render_reproduction_commands v0.9.9 "$release_dirs_text" \
	"$avr_build_dir" "$xt_build_dir" "$pic10f322_build_dir" \
	"$pic10f320_build_dir" "$pic12f675_build_dir" \
	"$selected_pic_cc" "$selected_pic_dfp" \
	"$selected_pic320_cc" "$selected_pic320_dfp" > "$reproduction"
bash -n "$reproduction" || fail "rendered reproduction commands are not valid shell"
: > "$render_log"
(
	cd "$render_fixture"
	PATH="$render_bin:$PATH" RENDER_LOG="$render_log" bash "$reproduction"
) || fail "rendered reproduction commands did not execute with synthetic tools"
checks=$((checks + 1))

grep -Fxq $'git\tcheckout\tv0.9.9' "$render_log" \
	|| fail "rendered reproduction recipe omitted the tag checkout"
expected=$(printf '%s\t%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s' \
	make clean AVR_BUILD_DIR "$avr_build_dir" XT_BUILD_DIR "$xt_build_dir" \
	PIC10F322_BUILD_DIR "$pic10f322_build_dir" \
	PIC10F320_BUILD_DIR "$pic10f320_build_dir" \
	PIC12F675_BUILD_DIR "$pic12f675_build_dir")
grep -Fxq "$expected" "$render_log" \
	|| fail "rendered reproduction clean does not preserve every selected build root"
expected=$(printf '%s\t%s\t%s\t%s\t%s=%s' make attiny13a attiny85 attiny45 \
	AVR_BUILD_DIR "$avr_build_dir")
grep -Fxq "$expected" "$render_log" \
	|| fail "rendered classic-AVR build does not preserve AVR_BUILD_DIR"
expected=$(printf '%s\t%s\t%s=%s\t%s=%s' make attiny202 \
	XT_BUILD_DIR "$xt_build_dir" STRICT_TOOLS 1)
grep -Fxq "$expected" "$render_log" \
	|| fail "rendered AVR-XT build does not preserve XT_BUILD_DIR and strict mode"
expected=$(printf '%s\t%s\t%s=%s\t%s=%s\t%s=%s' make pic10f322 \
	PIC10F322_BUILD_DIR "$pic10f322_build_dir" \
	PIC_CC "$selected_pic_cc" PIC_DFP "$selected_pic_dfp")
grep -Fxq "$expected" "$render_log" \
	|| fail "rendered reproduction recipe did not pin the shared PIC toolchain for PIC10F322"
expected=$(printf '%s\t%s\t%s=%s\t%s=%s\t%s=%s' make pic10f320-variants \
	PIC10F320_BUILD_DIR "$pic10f320_build_dir" \
	PIC10F320_CC "$selected_pic320_cc" PIC10F320_DFP "$selected_pic320_dfp")
grep -Fxq "$expected" "$render_log" \
	|| fail "rendered reproduction recipe did not pin the PIC10F320 toolchain"
expected=$(printf '%s\t%s\t%s=%s\t%s=%s\t%s=%s' make pic12f675 \
	PIC12F675_BUILD_DIR "$pic12f675_build_dir" \
	PIC_CC "$selected_pic_cc" PIC_DFP "$selected_pic_dfp")
grep -Fxq "$expected" "$render_log" \
	|| fail "rendered reproduction recipe did not build PIC12F675 with the shared PIC toolchain"
read -r -a release_dirs <<<"$release_dirs_text"
expected=$(printf 'verify\trelease/v0.9.9')
for dir in "${release_dirs[@]}"; do expected+=$(printf '\t%s' "$dir"); done
grep -Fxq "$expected" "$render_log" \
	|| fail "rendered reproduction verifier did not consume RELEASE_IMAGE_DIRS"
checks=$((checks + 1))

if release_render_reproduction_commands v0.9.9 \
		"$xt_build_dir $avr_build_dir $pic10f322_build_dir $pic10f320_build_dir $pic12f675_build_dir" \
		"$avr_build_dir" "$xt_build_dir" "$pic10f322_build_dir" \
		"$pic10f320_build_dir" "$pic12f675_build_dir" \
		"$selected_pic_cc" "$selected_pic_dfp" \
		"$selected_pic320_cc" "$selected_pic320_dfp" >/dev/null; then
	fail "reproduction renderer accepted build roots that disagree with RELEASE_IMAGE_DIRS"
fi
checks=$((checks + 1))

# The generated PIC12F675 flashing block is an executable guarded transaction,
# not an abbreviated writer command. Run it from a path with spaces and require
# fail-stop ordering between the read-only baseline and the write.
flashing="$work/rendered-pic12f675-flashing.md"
flashing_commands="$work/rendered-pic12f675-flashing.sh"
recovery_commands="$work/rendered-pic12f675-recovery.sh"
flashing_fixture="$work/rendered-flashcmds.txt"
git_safety_log="$work/rendered-pic12f675-git.log"
flash_fixture="$work/flash fixture with spaces"
mkdir -p "$flash_fixture"
printf '%s\t%s\n' \
	'bypass-attiny13a-cd4053_simple.hex' 'avrdude -c test-programmer' \
	'bypass-pic10f322-cd4053_simple.hex' 'pk2cmd -PPIC10F322 -Fimage.hex -M -Y -R' \
	> "$flashing_fixture"
helper_commands="$work/rendered-pic12f675-helper.sh"
helper_recovery="$work/rendered-pic12f675-helper-recovery.sh"
release_render_flashing "$flashing_fixture" v0.9.9 > "$flashing"
# Select each block by what it CONTAINS, not by its ordinal. The section now
# publishes four: the downloaded-image helper and its recovery, then the
# source-checkout transaction and its recovery. Positional extraction silently
# followed the wrong one when the helper blocks were added ahead of them.
extract_rendered_block() {
	awk -v want="$2" '
		/^```sh$/ { capture=1; buf=""; next }
		/^```$/ && capture {
			if (index(buf, want)) { printf "%s", buf; exit }
			capture=0
			next
		}
		capture { buf = buf $0 "\n" }
	' "$1"
}
extract_rendered_block "$flashing" 'pic12f675-release-program' > "$flashing_commands"
extract_rendered_block "$flashing" 'pic12f675-finalize' > "$recovery_commands"
extract_rendered_block "$flashing" 'flash-pic12f675.py program' > "$helper_commands"
extract_rendered_block "$flashing" 'flash-pic12f675.py finalize' > "$helper_recovery"
[ -s "$flashing_commands" ] \
	|| fail "rendered PIC12F675 flashing guidance has no shell command block"
[ -s "$recovery_commands" ] \
	|| fail "rendered PIC12F675 flashing guidance has no recovery command block"
[ -s "$helper_commands" ] \
	|| fail "rendered PIC12F675 flashing guidance has no downloaded-image helper block"
[ -s "$helper_recovery" ] \
	|| fail "rendered PIC12F675 flashing guidance has no helper recovery block"
bash -n "$flashing_commands" \
	|| fail "rendered PIC12F675 flashing commands are not valid shell"
bash -n "$recovery_commands" \
	|| fail "rendered PIC12F675 recovery commands are not valid shell"
bash -n "$helper_commands" \
	|| fail "rendered PIC12F675 helper commands are not valid shell"
bash -n "$helper_recovery" \
	|| fail "rendered PIC12F675 helper recovery commands are not valid shell"
# The published helper invocation must select a released image, name a NEW
# evidence directory, and carry no programmer write option of its own.
for required in '--image bypass-pic12f675-' '--ipecmd ' '--evidence-dir '; do
	grep -Fq -- "$required" "$helper_commands" \
		|| fail "rendered PIC12F675 helper command omits: $required"
done
grep -Fq -- '--evidence-dir' "$helper_recovery" \
	|| fail "rendered PIC12F675 helper recovery does not select the PENDING directory"
if grep -Fq -- '--image' "$helper_recovery"; then
	fail "rendered PIC12F675 helper recovery re-selects an image; recovery is read-only"
fi
for block in "$helper_commands" "$helper_recovery"; do
	if grep -Eq '(^|[[:space:]])-M([[:space:]]|$)' "$block"; then
		fail "rendered PIC12F675 helper block carries a raw programmer write option"
	fi
done
checks=$((checks + 1))
	for required in 'flash-pic12f675.py' 'NOT a raw write target' \
		'no source checkout' 'immutable PASS/FAIL' \
		'no trim damage was OBSERVED' \
		PIC12F675_TRIM_EVIDENCE PIC12F675_BENCH_RESULT \
		PIC12F675_RELEASE_TAG pic12f675-release-program pic12f675-finalize \
		'transaction is **PENDING**' 'physical custody' \
		'never invokes writer arguments' 'existing result' \
		'checked and recorded' 'hardware-unvalidated' \
		'may already have damaged the device' 'clean checkout of this exact annotated release tag' \
		'pinned tag and checksum signatures' 'complete signed release image set' \
		'does not consume a downloaded' 'outside the worktree' \
		'Shared `/tmp` and `/var/tmp` roots' \
		'No ipecmd hardware'; do
	grep -Fq "$required" "$flashing" \
		|| fail "rendered PIC12F675 flashing guidance omits: $required"
done
if grep -Fiq 'preserves factory OSCCAL/BG' "$flashing" \
		|| grep -Fq 'pk2cmd -PPIC12F675' "$flashing" \
		|| grep -Eq '(^|[[:space:]])ipecmd[[:space:]]+-' "$flashing"; then
	fail "rendered PIC12F675 flashing guidance claims preservation or publishes a raw writer command"
fi
grep -Fq 'flashcmd="" ;;' "$RELEASE" \
	|| fail "release producer still emits a per-image PIC12F675 flashing shortcut"
if grep -Fiq 'preserves factory OSCCAL/BG' "$RELEASE" \
		|| grep -Fq 'pk2cmd -PPIC12F675' "$RELEASE"; then
	fail "release producer still contains unsafe PIC12F675 flashing guidance outside the renderer"
fi
: > "$render_log"
: > "$git_safety_log"
(
	cd "$flash_fixture"
	PATH="$render_bin:$PATH" RENDER_LOG="$render_log" \
		GIT_SAFETY_LOG="$git_safety_log" bash "$flashing_commands"
) || fail "rendered PIC12F675 guarded flashing transaction did not execute"
mapfile -t flashing_log < "$render_log"
[ "${#flashing_log[@]}" -eq 2 ] \
	|| fail "rendered PIC12F675 transaction ran ${#flashing_log[@]} Make commands, expected 2"
baseline="$(dirname "$flash_fixture")/pic12f675-factory-baseline.json"
result="$(dirname "$flash_fixture")/pic12f675-program-result"
expected=$(printf '%s\t%s\t%s\t%s\t%s=%s\t%s=%s' make -C "$flash_fixture" \
	pic12f675-preflight \
	PIC12F675_READ_PROG pk2cmd PIC12F675_TRIM_EVIDENCE "$baseline")
[ "${flashing_log[0]}" = "$expected" ] \
	|| fail "rendered PIC12F675 preflight command is incomplete: ${flashing_log[0]}"
expected=$(printf '%s\t%s\t%s\t%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s' \
	make -C "$flash_fixture" pic12f675-release-program VARIANT cd4053_simple \
	PIC12F675_RELEASE_TAG v0.9.9 \
	PIC12F675_PROG pk2cmd PIC12F675_PROG_KIND pk2cmd \
	PIC12F675_READ_PROG pk2cmd PIC12F675_TRIM_EVIDENCE "$baseline" \
	PIC12F675_BENCH_RESULT "$result")
[ "${flashing_log[1]}" = "$expected" ] \
	|| fail "rendered PIC12F675 program command is incomplete: ${flashing_log[1]}"
if grep -Fq $'\tpic12f675-program\t' "$render_log"; then
	fail "rendered release guidance invoked the unsigned development programming goal"
fi
: > "$render_log"
repo="$flash_fixture" baseline="$baseline" result="$result" \
	PATH="$render_bin:$PATH" RENDER_LOG="$render_log" \
	bash "$recovery_commands" \
	|| fail "rendered PIC12F675 recovery command did not execute"
mapfile -t recovery_log < "$render_log"
[ "${#recovery_log[@]}" -eq 1 ] \
	|| fail "rendered PIC12F675 recovery ran ${#recovery_log[@]} commands, expected 1"
expected=$(printf '%s\t%s\t%s\t%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s\t%s=%s' \
	make -C "$flash_fixture" pic12f675-finalize \
	VARIANT cd4053_simple PIC12F675_RELEASE_TAG v0.9.9 \
	PIC12F675_PROG pk2cmd PIC12F675_PROG_KIND pk2cmd \
	PIC12F675_READ_PROG pk2cmd PIC12F675_TRIM_EVIDENCE "$baseline" \
	PIC12F675_BENCH_RESULT "$result")
[ "${recovery_log[0]}" = "$expected" ] \
	|| fail "rendered PIC12F675 recovery command is incomplete: ${recovery_log[0]}"
# The generated recovery command is held to the same published-finalization
# contract as the static documentation, by the same oracle -- the two drifted
# apart before v0.9.10 precisely because only the generated document carried
# PIC12F675_RELEASE_TAG.
release_validate_pic12f675_finalization_document "$flashing" \
	'rendered release flashing guidance' \
	|| fail "rendered PIC12F675 guidance fails the published-finalization contract"
checks=$((checks + 1))

mapfile -t git_safety_calls < "$git_safety_log"
[ "${#git_safety_calls[@]}" -eq 4 ] \
	&& [ "${git_safety_calls[0]}" = $'git\trev-parse\t--show-toplevel' ] \
	&& [ "${git_safety_calls[1]}" = "git"$'\t-C\t'"$flash_fixture"$'\trev-parse\t--verify\tHEAD^{commit}' ] \
	&& [ "${git_safety_calls[2]}" = "git"$'\t-C\t'"$flash_fixture"$'\trev-parse\t--verify\trefs/tags/v0.9.9^{commit}' ] \
	&& [ "${git_safety_calls[3]}" = "git"$'\t-C\t'"$flash_fixture"$'\tstatus\t--porcelain=v1\t--untracked-files=normal' ] \
	|| fail "rendered PIC12F675 transaction did not enforce exact-tag clean-source checks"
checks=$((checks + 1))

for failure in root head tag status; do
	: > "$render_log"
	: > "$git_safety_log"
	if (
		cd "$flash_fixture"
		PATH="$render_bin:$PATH" RENDER_LOG="$render_log" \
			GIT_SAFETY_LOG="$git_safety_log" GIT_COMMAND_FAIL="$failure" \
			bash "$flashing_commands"
	); then
		fail "rendered PIC12F675 transaction accepted failed Git $failure inspection"
	fi
	[ ! -s "$render_log" ] \
		|| fail "failed Git $failure inspection reached a PIC12F675 Make target"
done
checks=$((checks + 1))

: > "$render_log"
: > "$git_safety_log"
if (
	cd "$flash_fixture"
	PATH="$render_bin:$PATH" RENDER_LOG="$render_log" \
		GIT_SAFETY_LOG="$git_safety_log" GIT_WORKTREE_DIRTY=1 \
		bash "$flashing_commands"
); then
	fail "rendered PIC12F675 transaction accepted a dirty release-tag checkout"
fi
[ ! -s "$render_log" ] \
	|| fail "dirty release-tag checkout reached a PIC12F675 Make target"
checks=$((checks + 1))

: > "$render_log"
: > "$git_safety_log"
if (
	cd "$flash_fixture"
	PATH="$render_bin:$PATH" RENDER_LOG="$render_log" \
		GIT_SAFETY_LOG="$git_safety_log" GIT_TAG_MISMATCH=1 \
		bash "$flashing_commands"
); then
	fail "rendered PIC12F675 transaction accepted a checkout that was not the release tag"
fi
[ ! -s "$render_log" ] \
	|| fail "release-tag mismatch reached a PIC12F675 Make target"
checks=$((checks + 1))

printf '%s\t%s\n' 'bypass-pic12f675-cd4053_simple.hex' \
	'pk2cmd -PPIC12F675 -Fimage.hex -M -Y -R' > "$flashing_fixture"
if release_render_flashing "$flashing_fixture" v0.9.9 >/dev/null; then
	fail "assembled flashing renderer accepted a per-image PIC12F675 writer command"
fi
checks=$((checks + 1))

: > "$render_log"
if (
	cd "$flash_fixture"
	PATH="$render_bin:$PATH" RENDER_LOG="$render_log" \
		GIT_SAFETY_LOG="$git_safety_log" TEST_PREFLIGHT_FAIL=1 \
		bash "$flashing_commands"
); then
	fail "rendered PIC12F675 transaction continued after a failed preflight"
fi
mapfile -t flashing_log < "$render_log"
[ "${#flashing_log[@]}" -eq 1 ] \
	&& [[ "${flashing_log[0]}" == $'make\t-C\t'*$'\tpic12f675-preflight\t'* ]] \
	|| fail "failed rendered preflight did not stop before programming"
checks=$((checks + 1))

# Every directory handed to the verifier must have a corresponding build in the
# rendered recipe. Pin the five independent build roots so adding a sixth
# RELEASE_IMAGE_DIRS entry cannot leave the public procedure incomplete.
canonical_release_dirs_text=$(make -s --no-print-directory -C "$ROOT" \
	print-RELEASE_IMAGE_DIRS) \
	|| fail "could not read canonical RELEASE_IMAGE_DIRS"
read -r -a canonical_release_dirs <<<"$canonical_release_dirs_text"
[ "${#canonical_release_dirs[@]}" -eq 5 ] \
	|| fail "RELEASE_IMAGE_DIRS has ${#canonical_release_dirs[@]} entries, expected 5"
expected_canonical_dirs=()
for variable in AVR_BUILD_DIR XT_BUILD_DIR PIC10F322_BUILD_DIR \
		PIC10F320_BUILD_DIR PIC12F675_BUILD_DIR; do
	dir=$(make -s --no-print-directory -C "$ROOT" print-"$variable") \
		|| fail "could not read $variable"
	expected_canonical_dirs+=("$dir")
	[[ " ${canonical_release_dirs[*]} " == *" $dir "* ]] \
		|| fail "RELEASE_IMAGE_DIRS omits $variable=$dir"
done
[ "${canonical_release_dirs[*]}" = "${expected_canonical_dirs[*]}" ] \
	|| fail "RELEASE_IMAGE_DIRS does not use the renderer's canonical build-root order"
checks=$((checks + 1))

rendered_manifest="$work/rendered-manifest-sections.md"
{
	release_render_scope
	release_render_validation 24
	release_render_pic_toolchain_rows "$selected_pic_cc" 'XC8 shared version' \
		"$selected_pic320_cc" 'XC8 PIC10F320 version' \
		"$selected_pic_dfp" "$selected_pic320_dfp"
} > "$rendered_manifest"
grep -Fq 'PIC10F322, PIC10F320, and PIC12F675.' "$rendered_manifest" \
	|| fail "rendered release scope omits PIC12F675"
for target in pic10f322-test pic10f322-test-target-variants \
		pic10f320-test pic10f320-test-target-variants; do
	grep -Fq "\`make $target\`" "$rendered_manifest" \
		|| fail "rendered validation prose omits $target"
done
grep -Fq '`make pic12f675-test pic12f675-test-target-variants` (one retained matrix)' \
	"$rendered_manifest" \
	|| fail "rendered validation prose does not bind both PIC12F675 aggregates to one graph"
grep -Fq 'all three PIC parts' "$rendered_manifest" \
	|| fail "rendered validation prose does not describe all three PIC parts"
grep -Fq "| PIC10F322/PIC12F675 XC8 (\`PIC_CC=$selected_pic_cc\`) | XC8 shared version |" \
	"$rendered_manifest" \
	|| fail "rendered toolchain table does not attribute shared XC8 to PIC10F322 and PIC12F675"
grep -Fq "| PIC10F322/PIC12F675 DFP (\`PIC_DFP\`) | $selected_pic_dfp |" \
	"$rendered_manifest" \
	|| fail "rendered toolchain table does not attribute shared DFP to PIC10F322 and PIC12F675"
checks=$((checks + 1))

rendered_commit="$work/rendered-commit-message.txt"
release_render_commit_message v0.9.9 production abc1234 21 24 \
	> "$rendered_commit"
grep -Fq 'PIC10F320, and PIC12F675 -- 21 images' "$rendered_commit" \
	|| fail "rendered release commit message omits PIC12F675 scope"
grep -Fq 'make pic12f675-test pic12f675-test-target-variants (one retained matrix)' \
	"$rendered_commit" \
	|| fail "rendered release commit message does not bind both PIC12F675 aggregates to one graph"
grep -Fq 'Prebuilt, fully-validated firmware images for v0.9.9.' "$rendered_commit" \
	|| fail "rendered production commit message has the wrong release mode"
release_render_commit_message v0.9.9 dry-run abc1234 21 24 \
	> "$rendered_commit"
grep -Fq 'Non-publishable dry-run rehearsal images for v0.9.9.' "$rendered_commit" \
	|| fail "rendered dry-run commit message has the wrong release mode"
if release_render_commit_message v0.9.9 invalid abc1234 21 24 >/dev/null; then
	fail "release commit-message renderer accepted an invalid release mode"
fi
checks=$((checks + 1))

printf 'release qualification validation: %d checks, 0 failures\n' "$checks"
