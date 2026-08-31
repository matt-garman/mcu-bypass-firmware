#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-release-qualification.sh"
RENDER="$ROOT/scripts/release-documentation.sh"
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
# A well-formed commit that is not the one being released, for the controls
# that test evidence retained from a different run.
other_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
version=v99.0.0
checks=0
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -r "$RENDER" ] || fail "release documentation renderer is missing"
[ -r "$MATRIX_TOOL" ] || fail "PIC12F675 matrix evidence helper is missing"
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
		release_render_toolchain_table release_render_pic12f675_flashing \
		release_render_flashing \
		release_render_reproduction_commands \
		release_render_commit_message; do
	declare -F "$function" >/dev/null \
		|| fail "release documentation renderer omitted $function"
done
checks=$((checks + 1))

# The PIC12F675 release disposition, and the residual risk that goes with it.
#
# This used to be pinned inside the port assessment's bounded current-status
# block, which was a summary of facts owned elsewhere -- and a summary is
# exactly the thing that drifts. The assessment is gone; the two documents that
# own those facts are checked instead:
#
#   * TODO.md's T3-pic12f675-bench is now the DEFINITION of the four open
#     silicon-only risks, not a restatement of one. The Makefile, the CI notes
#     and the release documentation all cite them by their original numbers, so
#     the enumeration has to stay complete and stay in one place; dropping an
#     item here is how a residual risk stops being tracked while every citation
#     still reads as if it were.
#   * DESIGN_DOCUMENTATION.adoc states the disposition itself: release-supported
#     in software, controlled hardware qualification deferred.
#
# The contradiction check then runs over both, so neither can quietly promote
# the guarded workflow into a preservation guarantee or demote the part.
pic12f675_bench=$(awk '
	/^### T3-pic12f675-bench/ { keep=1; next }
	keep && /^### / { exit }
	keep { print }
' "$ROOT/TODO.md") || fail "TODO.md could not be scanned for T3-pic12f675-bench"
[ -n "$pic12f675_bench" ] \
	|| fail "TODO.md has no T3-pic12f675-bench section"
pic12f675_bench_one_line=$(printf '%s\n' "$pic12f675_bench" \
	| tr '\n' ' ' | tr -s ' ')
for required in \
		'**release-supported from `v0.9.9`**' \
		'no controlled hardware-qualification record' \
		'**1 - bandgap calibration bits (`BG<1:0>`) preserved on program.**' \
		'**2 - factory oscillator trim (flash word 0x3FF) preserved on program.**' \
		'**8 - `ipecmd` actually runs against the part.**' \
		"**9 - GP2's readback margin.**"; do
	grep -Fq "$required" <<<"$pic12f675_bench_one_line" \
		|| fail "TODO.md T3-pic12f675-bench omits release/residual-risk semantics: $required"
done
pic12f675_disposition=$(awk '
	/^A third PIC, the PIC12F675,/ { keep=1 }
	keep && /^== / { exit }
	keep { print }
' "$DESIGN_DOCUMENTATION") \
	|| fail "design documentation could not be scanned for the PIC12F675 disposition"
[ -n "$pic12f675_disposition" ] \
	|| fail "design documentation states no PIC12F675 release disposition"
pic12f675_disposition_one_line=$(printf '%s\n' "$pic12f675_disposition" \
	| tr '\n' ' ' | tr -s ' ')
for required in \
		'**release-supported from `v0.9.9`**' \
		'has **not** completed controlled hardware qualification' \
		'deferred to the `1.x.y` pass (TODO `T3-pic12f675-bench`)'; do
	grep -Fq "$required" <<<"$pic12f675_disposition_one_line" \
		|| fail "design documentation omits the PIC12F675 release disposition: $required"
done
if grep -Eiq '(PIC12F675|the part|this part) (is|remains) (intentionally )?(not release-supported|(absent from|excluded from|not included in) (the )?(default `all` goal|CI|release integration|(canonical )?([0-9]+-image )?release set))|(^|[.!?] )((the|this|a) )?(workflow|programmer|pk2cmd|ipecmd) (preserves|guarantees|ensures)([ .]|$)|(^|[.!?] )(factory trim|factory values|OSCCAL|BG) (is|are) preserved([ .]|$)' \
		<<<"$pic12f675_bench_one_line $pic12f675_disposition_one_line"; then
	fail "PIC12F675 documentation contradicts its release-supported disposition"
fi
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

# The release authority must retain its current and historical contracts. The
# test assurance map must retain key target coverage and hardware-gap sections.
# Exact counts and inventories stay in their executable owners rather than
# becoming required reader-facing prose here.
release_contract=$(tr '\n' ' ' < "$RELEASE_README" | tr -s ' ')
test_contract=$(tr '\n' ' ' < "$TEST_README" | tr -s ' ')
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
		'## Known gaps (PIC — hardware-bench only)' \
		'### PIC10F32x hardware gaps' \
		'### PIC12F675 hardware gaps'; do
	grep -Fq "$required" <<<"$test_contract" \
		|| fail "test README omits current PIC/release scope: $required"
done
checks=$((checks + 1))

for wiring in \
	$'\trelease_render_scope' \
	$'\trelease_render_validation "$hours"' \
	$'\trelease_render_toolchain_table "$EVID/toolchain.txt" \\' \
	$'\tcheck_flash_commands "$WORK/flashcmds.txt"' \
	$'\trelease_render_flashing "$WORK/flashcmds.txt" "$VERSION" \\' \
	$'\t\t"$AVR_PROGRAMMER" "$XT_PROGRAMMER" "$XT_UPDI_PORT"' \
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

mapfile -t test_long_run_lines < <(grep -nF \
	'make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0 PIC12F675_FLASH_IMAGES=build' \
	"$RELEASE")
mapfile -t test_long_result_lines < <(grep -nF \
	'TEST_LONG_RESULT format=1 status=pass source_commit=%s target=test-long strict_tools=1 mutation_allow_skip=0' \
	"$RELEASE")
[ "${#test_long_run_lines[@]}" -eq 1 ] \
	&& [ "${#test_long_result_lines[@]}" -eq 1 ] \
	|| fail "release producer test-long invocation/result markers are missing or ambiguous"
test_long_run_line=${test_long_run_lines[0]%%:*}
test_long_result_line=${test_long_result_lines[0]%%:*}
[ "$test_long_run_line" -lt "$test_long_result_line" ] \
	|| fail "release producer records test-long success before invoking the aggregate"
if grep -Fq 'full log is reproduced (and archived)' "$RELEASE"; then
	fail "release producer still claims tag CI durably archives the full test-long log"
fi
checks=$((checks + 1))

# D4: the strict resource gate runs exactly twice, and neither run is optional.
# The first is a fail-fast: it reads the same gate logs and images, so it must
# run BEFORE the soak starts, and it must report OUTSIDE $EVID -- staging copies
# every $EVID/*.log into the release, where the retained set must equal
# RELEASE_EVIDENCE_FILES exactly. The second is the retained record: it must
# consume the post-qualification logs and the final regenerated image set, not
# the initial clean build, and it must land before the final source-provenance
# check and staging.
for wiring in \
	'python3 "$REPO_ROOT/test/test_resource_tables.py" --root "$REPO_ROOT"' \
	'--require-all-images --evidence-dir "$EVID" --source-commit "$GIT_SHA"' \
	'>"$EVID/resource-tables.log" 2>&1' \
	'>"$WORK/resource-tables-presoak.log" 2>&1'; do
	grep -Fq -- "$wiring" "$RELEASE" \
		|| fail "release producer omits strict resource-evidence wiring: $wiring"
done
resource_invocations=$(grep -Fc -- \
	'python3 "$REPO_ROOT/test/test_resource_tables.py" --root "$REPO_ROOT"' "$RELEASE")
[ "$resource_invocations" -eq 2 ] \
	|| fail "release producer must run the strict resource gate exactly twice (found $resource_invocations)"
presoak_resource_line=$(grep -Fn -- '>"$WORK/resource-tables-presoak.log" 2>&1' \
	"$RELEASE" | cut -d: -f1)
soak_section_line=$(grep -Fn -- 'section "3. soak (all release combos, parallel' \
	"$RELEASE" | cut -d: -f1)
final_image_line=$(grep -n 'regenerating classic AVR HEX from the validated ELFs' \
	"$RELEASE" | cut -d: -f1)
resource_line=$(grep -Fn -- '>"$EVID/resource-tables.log" 2>&1' "$RELEASE" | cut -d: -f1)
final_source_line=$(grep -n 'if ! release_source_is_unchanged "$GIT_SHA" "$DRY_RUN"' \
	"$RELEASE" | cut -d: -f1)
[[ "$presoak_resource_line" =~ ^[0-9]+$ && "$soak_section_line" =~ ^[0-9]+$ \
	&& "$presoak_resource_line" -lt "$soak_section_line" ]] \
	|| fail "the fail-fast resource gate does not run before the soak section"
[[ "$final_image_line" =~ ^[0-9]+$ && "$resource_line" =~ ^[0-9]+$ \
	&& "$final_source_line" =~ ^[0-9]+$ \
	&& "$final_image_line" -lt "$resource_line" \
	&& "$resource_line" -lt "$final_source_line" ]] \
	|| fail "strict resource evidence is not between final image regeneration and the final source check"
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
read -r -a evidence_role_entries \
	<<<"$(make -s --no-print-directory -C "$ROOT" CC=: print-RELEASE_EVIDENCE_ROLES)"
declare -A fixture_role=()
for role_entry in "${evidence_role_entries[@]}"; do
	fixture_role[${role_entry%%=*}]=${role_entry#*=}
done
read -r -a canonical_images \
	<<<"$(make -s --no-print-directory -C "$ROOT" CC=: print-RELEASE_IMAGES)"
fw_base=$(make -s --no-print-directory -C "$ROOT" CC=: print-FW_BASE)
pic12f675_tag=$(make -s --no-print-directory -C "$ROOT" CC=: print-PIC12F675_TAG)
xt_tag=$(make -s --no-print-directory -C "$ROOT" CC=: print-XT_TAG)
read -r -a pic12f675_variants \
	<<<"$(make -s --no-print-directory -C "$ROOT" CC=: print-CLASSIC_VARIANTS_SUPPORTED)"

# The fixture's own resource-record producer and row renderer, written to mirror
# what test_resource_tables.py emits and what make-release.sh renders rather than
# to import either. A fixture that called the release script's own renderer could
# not catch the producer and the verifier disagreeing, which is the whole point
# of the verifier re-deriving these rows.
#
# Every figure is arbitrary and unlike the real matrix, so this fixture does not
# fail on a firmware size change; the arithmetic each record must close on is
# real, because that is what is under test.
resource_fixture_ceiling=1000
resource_fixture_capacity=1200
declare -A resource_fixture_cell=()
resource_fixture_rows=()

write_resource_evidence() {
	local image part unit label used free index=0 avr=() pic=() variants=()
	local seen_part=" " seen_variant=" " variant
	for image in "${canonical_images[@]}"; do
		part=${image#*-}; part=${part%%-*}
		variant=${image##*-}; variant=${variant%.hex}
		case "$seen_part" in
			*" $part "*) ;;
			*) seen_part="$seen_part$part "
			   case "$part" in pic*) pic+=("$part") ;; *) avr+=("$part") ;; esac ;;
		esac
		case "$seen_variant" in
			*" $variant "*) ;;
			*) seen_variant="$seen_variant$variant "; variants+=("$variant") ;;
		esac
	done
	resource_fixture_cell=()
	resource_fixture_rows=()
	{
		printf 'resource tables: fixture checks, 0 failures (%d of %d canonical images measured; complete candidate required)\n' \
			"${#canonical_images[@]}" "${#canonical_images[@]}"
		for image in "${canonical_images[@]}"; do
			part=${image#*-}; part=${part%%-*}
			case "$part" in pic*) unit=words; label=words ;; *) unit=bytes; label=B ;; esac
			used=$(( 300 + index ))
			free=$(( resource_fixture_ceiling - used ))
			printf 'RESOURCE_IMAGE format=1 image=%s part=%s unit=%s used=%d ceiling=%d capacity=%d free=%d method=fixture\n' \
				"$image" "$part" "$unit" "$used" "$resource_fixture_ceiling" \
				"$resource_fixture_capacity" "$free"
			resource_fixture_cell[$image]="$used / $resource_fixture_ceiling $label ($free free)"
			index=$(( index + 1 ))
		done
		for part in "${avr[@]}"; do
			printf 'RESOURCE_STATIC format=1 part=%s unit=bytes static=6 ceiling=20 free=14 images=3 method=fixture\n' \
				"$part"
			resource_fixture_rows+=("$(printf '| `%s` | 6 B | 20 B | 14 B | 3 |' "$part")")
		done
		# The record identities are part of the contract, not arbitrary labels:
		# Classic AVR parts carry observed high-water rows and the AVR-XT carries
		# the compiler's per-frame bound.
		for part in "${avr[@]}"; do
			[ "$part" = "$xt_tag" ] && continue
			printf 'RESOURCE_STACK format=1 part=%s unit=bytes method=fixture-high-water observations=3 deepest_sp=0x0F0 used=30 free=44 static=6 sram=80 floor=10\n' \
				"$part"
			resource_fixture_rows+=("$(printf '| `%s` | 0x0F0 | 30 B | 44 B | 6 B | 80 B | 10 B | 3 |' "$part")")
		done
		part=$xt_tag
		printf 'RESOURCE_STACK_BOUND format=1 part=%s unit=bytes method=fixture-frame-bound reports=3 ceiling=40\n' \
			"$part"
		resource_fixture_rows+=("$(printf '| `%s` | fixture-frame-bound | 3 | every frame <= 40 B |' "$part")")
		for variant in "${variants[@]}"; do
			printf 'RESOURCE_DATA format=1 part=%s variant=%s unit=bytes method=fixture used=25 ceiling=45 capacity=60 free=20\n' \
				"$pic12f675_tag" "$variant"
			resource_fixture_rows+=("$(printf '| `%s` | %s | 25 B | 45 B | 60 B | 20 B |' "$pic12f675_tag" "$variant")")
		done
		for part in "${pic[@]}"; do
			for variant in "${variants[@]}"; do
				printf 'RESOURCE_RETURN_STACK format=1 part=%s variant=%s unit=levels method=fixture peak=3 reserve=1 spare=2 depth=6\n' \
					"$part" "$variant"
				resource_fixture_rows+=("$(printf '| `%s` | %s | 3 | 1 | 2 | 6 |' "$part" "$variant")")
			done
		done
		printf 'RESOURCE_TABLES_RESULT format=1 status=pass source_commit=%s images=21 avr_static=12 classic_stack=9 pic_data=6 pic_stack=9 records=%d\n' \
			"$sha" "$(( ${#canonical_images[@]} + ${#resource_fixture_rows[@]} ))"
	} > "$release/evidence/resource-tables.log"
}

reset_fixture() {
	local mode=${1:-production}
	local duration=${2:-86400000}
	local liveness=${3:-60000}
	local dirty=${4:-0}
	local expected_checks=$((duration / liveness)) name file variant stem
	local matrix_record matrix_digest resource_digest index_digest
	rm -rf "$release" "$matrix_build"
	mkdir -p "$release/evidence" "$matrix_build/simcal"
	for file in "${evidence_names[@]}"; do
		printf 'retained evidence: %s\n' "$file" > "$release/evidence/$file"
	done
	cat > "$release/evidence/test-long.summary.txt" <<EOF
# test-long retained result

TEST_LONG_RESULT format=1 status=pass source_commit=$sha target=test-long strict_tools=1 mutation_allow_skip=0
EOF
	write_resource_evidence
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
	resource_digest=$(sha256sum -- "$release/evidence/resource-tables.log")
	resource_digest=${resource_digest%% *}
	# Fifteen recorded tools, the count the verifier requires, written in the
	# same tab-separated form make-release.sh produces.
	{
		printf 'TOOLCHAIN format=1 source_commit=%s\n' "$sha"
		for tool_index in $(seq 1 15); do
			printf 'fixture-tool-%s\t1.%s.0\n' "$tool_index" "$tool_index"
		done
		printf 'TOOLCHAIN_RESULT format=1 status=pass rows=15 source_commit=%s\n' \
			"$sha"
	} > "$release/evidence/toolchain.txt"
	toolchain_digest=$(sha256sum -- "$release/evidence/toolchain.txt")
	toolchain_digest=${toolchain_digest%% *}
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
	# Every retained file is final at this point, so the index can describe them
	# all; QUALIFICATION cites its digest on the very next line.
	write_evidence_index
	index_digest=$(sha256sum -- "$release/evidence/INDEX")
	index_digest=${index_digest%% *}
	cat > "$release/QUALIFICATION" <<EOF
format=7
version=$version
release_mode=$mode
source_commit=$sha
source_dirty=$dirty
soak_duration_ms=$duration
soak_liveness_interval_ms=$liveness
soak_combination_count=${#soak_names[@]}
pic12f675_matrix_sha256=$matrix_digest
resource_tables_sha256=$resource_digest
toolchain_sha256=$toolchain_digest
evidence_index_sha256=$index_digest
EOF
	{
		printf '# Firmware release %s\n\n' "$version"
		[ "$mode" != dry-run ] \
			|| printf '> **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.\n\n'
		[ "$mode" != express ] \
			|| printf '> **EXPRESS QUALIFICATION -- SHORTENED SOAK.** Every gate below ran in full; the parallel soak ran 1.0 h per combination instead of 24 h.\n\n'
		printf -- '- **Release mode:** %s\n' "$mode"
		printf -- '- **Source commit:** `%s`\n' "$sha"
		printf -- '- **Soak duration per combination:** %s ms\n' "$duration"
		printf -- '- **Soak combinations:** %s\n' "${#soak_names[@]}"
		printf -- '- **PIC12F675 qualified matrix:** `evidence/pic12f675-qualified-matrix.json` (SHA-256 `%s`)\n' \
			"$matrix_digest"
		printf -- '- **Final resource evidence:** `evidence/resource-tables.log` (SHA-256 `%s`)\n' \
			"$resource_digest"
		printf -- '- **Evidence index:** `evidence/INDEX` (SHA-256 `%s`), %d retained files by role and terminal record\n' \
			"$index_digest" "${#fixture_role[@]}"
		printf '\n## Toolchain\n\n'
		printf -- '| tool | version |\n|---|---|\n'
		for tool_index in $(seq 1 15); do
			printf -- '| fixture-tool-%s | 1.%s.0 |\n' "$tool_index" "$tool_index"
		done
		printf '\n## Images\n\n'
		printf -- '| image | MCU | clock | flash used / reviewed ceiling | fuses / config | sha256 |\n'
		printf -- '|---|---|---|---|---|---|\n'
		for image in "${canonical_images[@]}"; do
			printf -- '| `%s` | fixture-mcu | fixture-clock | %s | %s | `%s` |\n' \
				"$image" "${resource_fixture_cell[$image]}" \
				"$(fixture_fuse_cell "$image")" \
				"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		done
		printf '\n## Resources\n\n'
		printf '%s\n' "${resource_fixture_rows[@]}"
		write_flashing_section
	} > "$release/MANIFEST.md"
	{
		printf '# %s\n\n' "$version"
		[ "$mode" != dry-run ] \
			|| printf '> **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.\n\n'
		[ "$mode" != express ] \
			|| printf '> **EXPRESS QUALIFICATION -- SHORTENED SOAK.** Every gate below ran in full; the parallel soak ran 1.0 h per combination instead of 24 h.\n\n'
		printf 'Prebuilt firmware for %s. See **MANIFEST.md** for provenance.\n' "$version"
	} > "$release/README.md"
	reseal_provenance
}

# The fuse cell and the flashing command for one fixture image are written by
# two different functions here on purpose: the verifier's new obligation is that
# the bytes a reader is shown in the Images table are the bytes the command they
# paste actually writes, and a fixture that rendered both from one expression
# could not tell whether that obligation is checked.
fixture_fuse_cell() {
	case "$1" in
		*-pic*) printf 'fixture-config\n' ;;
		*)      printf 'lfuse=0x5a hfuse=0xf9\n' ;;
	esac
}

fixture_flash_command() {
	case "$1" in
		*-pic*) printf 'pk2cmd -Pfixture -F%s -M -Y -R\n' "$1" ;;
		*)      printf 'avrdude -c usbtiny -p fixture -U lfuse:w:0x5a:m -U hfuse:w:0xf9:m -U flash:w:%s:i\n' "$1" ;;
	esac
}

# Mirrors release_render_flashing's published shape without calling it, for the
# same reason write_evidence_index mirrors the index writer.
write_flashing_section() {
	local image stem source_image
	printf '\n## Flashing\n\n'
	printf 'Fixture flashing prose.\n\n'
	printf '### Programmer profiles\n\n'
	printf '| images | interface | tool | this release publishes | if yours differs |\n'
	printf '|---|---|---|---|---|\n'
	printf '| fixture | ISP | `avrdude` | `-c usbtiny` | fixture |\n\n'
	printf '### Per-image commands\n\n'
	printf '```sh\n'
	for image in "${canonical_images[@]}"; do
		case "$image" in
			*-pic12f675-*) continue ;;
		esac
		printf '# %s\n%s\n\n' "$image" "$(fixture_flash_command "$image")"
	done
	printf '```\n\n'
	source_image=""
	for image in "${canonical_images[@]}"; do
		case "$image" in
			*-pic12f675-*) continue ;;
			*) source_image=$image; break ;;
		esac
	done
	[ -n "$source_image" ] || return 1
	stem=${source_image%.hex}
	printf '### Source-checkout equivalents\n\n'
	printf '```sh\n'
	printf '# %s\n' "$source_image"
	printf 'make fixture-program VARIANT=%s\n\n' "${stem##*-}"
	printf '```\n\n'
}

# The fixture's own index producer, deliberately written to mirror the shape
# make-release.sh emits rather than to import it: a fixture that called the
# release script's own writer could not catch the two of them disagreeing, which
# is the failure that reached a commit last time this pattern was extended.
#
# Appends the terminal record to every build/target-test log first, because that
# changes their size and the index records sizes.
write_evidence_index() {
	local name role size record lines payload_digest
	for name in "${!fixture_role[@]}"; do
		role=${fixture_role[$name]}
		case "$role" in build|target-test) ;; *) continue ;; esac
		grep -q '^EVIDENCE_RESULT ' "$release/evidence/$name" && continue
		lines=$(wc -l < "$release/evidence/$name")
		payload_digest=$(sha256sum -- "$release/evidence/$name")
		payload_digest=${payload_digest%% *}
		printf 'EVIDENCE_RESULT format=2 status=pass role=%s evidence=%s lines=%d payload_sha256=%s source_commit=%s\n' \
			"$role" "$name" "$lines" "$payload_digest" "$sha" \
			>> "$release/evidence/$name"
	done
	{
		printf 'EVIDENCE_INDEX format=2 source_commit=%s\n' "$sha"
		while IFS= read -r name; do
			role=${fixture_role[$name]}
			size=$(stat -c%s "$release/evidence/$name")
			case "$role" in
				build|target-test)
					record=$(grep -m1 '^EVIDENCE_RESULT ' "$release/evidence/$name") ;;
				soak)
					record=$(grep -m1 '^SOAK_RESULT ' "$release/evidence/$name") ;;
				test-long)
					record=$(grep -m1 '^TEST_LONG_RESULT ' "$release/evidence/$name") ;;
				resource)
					record=$(grep -m1 '^RESOURCE_TABLES_RESULT ' "$release/evidence/$name") ;;
				toolchain)
					record=$(grep -m1 '^TOOLCHAIN_RESULT ' "$release/evidence/$name") ;;
				*) record='-' ;;
			esac
			printf '%s\t%s\t%s\t%s\n' "$name" "$role" "$size" "$record"
		done < <(printf '%s\n' "${!fixture_role[@]}" | sort)
		printf 'EVIDENCE_INDEX_RESULT format=2 status=pass members=%d source_commit=%s\n' \
			"${#fixture_role[@]}" "$sha"
	} > "$release/evidence/INDEX"
}

# Re-pin the index digest WITHOUT re-rendering the index. Controls that corrupt
# the index itself need this: refresh_evidence_index would regenerate the file
# and quietly undo the very edit under test, leaving a control that passes
# because it tests nothing.
reseal_evidence_index() {
	local old_digest new_digest
	old_digest=$(awk -F= '$1 == "evidence_index_sha256" { print $2 }' \
		"$release/QUALIFICATION")
	new_digest=$(sha256sum -- "$release/evidence/INDEX")
	new_digest=${new_digest%% *}
	sed -i "s/$old_digest/$new_digest/g" \
		"$release/QUALIFICATION" "$release/MANIFEST.md"
	reseal_provenance
}

# Bring one index row back into step with a log a control has just edited, using
# exactly the derivation the verifier uses, so the control proves what it is
# about instead of tripping the size or record check on the way there.
restate_index_row() {
	local name=$1 role size lines payload_lines payload_digest record
	role=${fixture_role[$name]}
	size=$(stat -c%s "$release/evidence/$name")
	lines=$(wc -l < "$release/evidence/$name")
	payload_lines=$((lines - 1))
	payload_digest=$(head -n "$payload_lines" "$release/evidence/$name" | sha256sum)
	payload_digest=${payload_digest%% *}
	record="EVIDENCE_RESULT format=2 status=pass role=$role evidence=$name lines=$payload_lines payload_sha256=$payload_digest source_commit=$sha"
	sed -i "s|^${name//./\\.}\t.*|$name\t$role\t$size\t$record|" \
		"$release/evidence/INDEX"
	reseal_evidence_index
}

# The index binds every member's size and terminal record, so a control that
# legitimately rewrites evidence to reach a LATER check has to re-render it --
# exactly as the toolchain and resource digests have to be re-pinned.
refresh_evidence_index() {
	local old_digest new_digest
	old_digest=$(awk -F= '$1 == "evidence_index_sha256" { print $2 }' \
		"$release/QUALIFICATION")
	write_evidence_index
	new_digest=$(sha256sum -- "$release/evidence/INDEX")
	new_digest=${new_digest%% *}
	sed -i "s/$old_digest/$new_digest/g" \
		"$release/QUALIFICATION" "$release/MANIFEST.md"
	reseal_provenance
}

# The provenance files are inside SHA256SUMS as of QUALIFICATION format=4, so
# anything that legitimately rewrites one has to re-pin it. A test that mutates
# a provenance file to make the verifier reject it must NOT call this -- the
# unsealed digest is part of what such an edit breaks in a real release.
reseal_provenance() {
	local provenance_names
	provenance_names=$(make -s --no-print-directory -C "$ROOT" print-RELEASE_PROVENANCE_FILES)
	(
		cd "$release"
		grep -v -E '  (QUALIFICATION|MANIFEST\.md|README\.md)$' SHA256SUMS > SHA256SUMS.tmp || true
		mv SHA256SUMS.tmp SHA256SUMS
		# shellcheck disable=SC2086
		sha256sum -- $provenance_names >> SHA256SUMS
	)
}

refresh_matrix_digest() {
	local old_digest new_digest
	old_digest=$(awk -F= '$1 == "pic12f675_matrix_sha256" { print $2 }' \
		"$release/QUALIFICATION")
	new_digest=$(sha256sum -- "$release/evidence/pic12f675-qualified-matrix.json")
	new_digest=${new_digest%% *}
	sed -i "s/$old_digest/$new_digest/g" \
		"$release/QUALIFICATION" "$release/MANIFEST.md"
	refresh_evidence_index
}

# The toolchain digest is bound from QUALIFICATION, so a control that mutates
# the evidence to test a LATER check has to re-pin it first -- otherwise the
# digest check fires and the control proves the wrong thing.
refresh_toolchain_digest() {
	local old_digest new_digest
	old_digest=$(awk -F= '$1 == "toolchain_sha256" { print $2 }' \
		"$release/QUALIFICATION")
	new_digest=$(sha256sum -- "$release/evidence/toolchain.txt")
	new_digest=${new_digest%% *}
	sed -i "s/$old_digest/$new_digest/g" "$release/QUALIFICATION"
	refresh_evidence_index
}

refresh_resource_digest() {
	local old_digest new_digest
	old_digest=$(awk -F= '$1 == "resource_tables_sha256" { print $2 }' \
		"$release/QUALIFICATION")
	new_digest=$(sha256sum -- "$release/evidence/resource-tables.log")
	new_digest=${new_digest%% *}
	sed -i "s/$old_digest/$new_digest/g" \
		"$release/QUALIFICATION" "$release/MANIFEST.md"
	refresh_evidence_index
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
printf 'format=7\n' >> "$release/QUALIFICATION"
expect_fail "duplicate qualification key" "duplicate QUALIFICATION key"

# Format 6 is the superseded length-attributed evidence contract. It is rejected
# rather than accepted as a legacy mode because this verifier only runs on a
# directory being staged or a tag being published.
reset_fixture
sed -i 's/^format=7$/format=6/' "$release/QUALIFICATION"
expect_fail "superseded qualification format" "unsupported QUALIFICATION format"

reset_fixture
sed -i 's/^format=7$/format=2/' "$release/QUALIFICATION"
expect_fail "obsolete qualification format" "unsupported QUALIFICATION format"

reset_fixture
printf 'changed resource evidence\n' >> "$release/evidence/resource-tables.log"
expect_fail "changed resource evidence" "resource evidence digest does not match"

reset_fixture
sed -i 's/images=21/images=20/' "$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "incomplete resource result" "no exact source-bound complete result"

reset_fixture
sed -i 's/resource-tables.log` (SHA-256 `[0-9a-f]\{64\}`)/resource-tables.log` (SHA-256 `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`)/' \
	"$release/MANIFEST.md"
expect_fail "wrong manifest resource digest" "MANIFEST.md resource evidence digest"

# --- the measured figures, and the manifest rows derived from them -----------
# The release used to publish a flash column the producer derived for itself and
# no one checked, including three "n/a" cells where it derived nothing at all.
# Every figure now comes from a record in this log, so every way a record and a
# published row can disagree is a control here.

reset_fixture
grep -v "^RESOURCE_IMAGE format=1 image=${canonical_images[0]} " \
	"$release/evidence/resource-tables.log" > "$work/resource.tmp"
mv "$work/resource.tmp" "$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "unmeasured release image" "no measured resource record for the release image"

reset_fixture
printf 'RESOURCE_IMAGE format=1 image=bypass-nosuch-cd4053_simple.hex part=nosuch unit=bytes used=300 ceiling=1000 capacity=1200 free=700 method=fixture\n' \
	>> "$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "record for an unshipped image" "unexpected resource identity: RESOURCE_IMAGE|"

reset_fixture
head -2 "$release/evidence/resource-tables.log" | tail -1 \
	>> "$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "duplicate image measurement" "duplicate resource identity: RESOURCE_IMAGE|"

reset_fixture
sed -i '0,/^RESOURCE_IMAGE /s/ free=/ free=1/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "free margin that does not close" "free margin that is not its ceiling less its use"

reset_fixture
sed -i '0,/^RESOURCE_IMAGE /s/ capacity=1200/ capacity=900/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "ceiling wider than the device" "does not order use, ceiling and capacity"

reset_fixture
sed -i '0,/^RESOURCE_STACK /s/ sram=80/ sram=81/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "stack record that loses SRAM" "does not account for the whole device SRAM"

reset_fixture
sed -i '0,/^RESOURCE_RETURN_STACK /s/ spare=2/ spare=3/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "return-stack record that loses a level" "does not account for the whole hardware stack"

# Every field is accounted for before interpretation. A repeated value is not a
# harmless restatement: accepting it would make parser choice decide which
# signed evidence the release means.
reset_fixture
sed -i '0,/^RESOURCE_DATA /s/ used=25/ used=25 used=25/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "duplicate resource field" "RESOURCE_DATA record repeats field: used"

# A per-frame compiler bound is not a whole-path high-water measurement, and the
# release must not be able to publish it as one.
reset_fixture
sed -i 's/^\(RESOURCE_STACK_BOUND .*\)$/\1 used=99/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "frame bound claiming a high-water figure" "RESOURCE_STACK_BOUND record has unknown field: used"

reset_fixture
sed -i 's/^\(RESOURCE_STACK_BOUND .*\) reports=3/\1 reports=three/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "non-decimal measurement" "has no decimal reports field"

reset_fixture
printf 'RESOURCE_INVENTED format=1 unit=bytes value=1\n' \
	>> "$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "unknown resource record" "unknown resource record in the resource evidence"

reset_fixture
sed -i 's/^RESOURCE_TABLES_RESULT /RESOURCE_TABLES_RESULT reviewed=1 /' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "unknown terminal resource field" "RESOURCE_TABLES_RESULT record has unknown field: reviewed"

# Record counts do not prove topology. These controls duplicate, remove or
# invent an identity while the terminal result continues to claim 41 records.
reset_fixture
sed -i '0,/^RESOURCE_DATA .*variant=cd4053_simple /s/variant=cd4053_simple/variant=cd4053_with_mute/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "duplicate Data-space identity" "duplicate resource identity: RESOURCE_DATA|$pic12f675_tag/cd4053_with_mute"

reset_fixture
grep -v '^RESOURCE_DATA .*variant=cd4053_simple ' \
	"$release/evidence/resource-tables.log" > "$work/resource.tmp"
mv "$work/resource.tmp" "$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "missing Data-space identity" "missing resource identity: RESOURCE_DATA|$pic12f675_tag/cd4053_simple"

reset_fixture
sed -i '0,/^RESOURCE_STATIC /{ /^RESOURCE_STATIC /s/part=[^ ]*/part=nosuch/; }' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "substituted static-resource identity" "unexpected resource identity: RESOURCE_STATIC|nosuch"

reset_fixture
sed -i '0,/^RESOURCE_IMAGE /s/ part=[^ ]*/ part=nosuch/' \
	"$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "image attributed to another part" "is attributed to nosuch, expected"

reset_fixture
sed -i 's/ records=41$/ records=40/' "$release/evidence/resource-tables.log"
refresh_resource_digest
expect_fail "terminal count below the records present" "no exact source-bound complete result"

reset_fixture
victim=${canonical_images[0]}
sed -i "s|${resource_fixture_cell[$victim]}|999 / 1000 B (1 free)|" \
	"$release/MANIFEST.md"
expect_fail "manifest flash cell that was not measured" "the measured record says"

reset_fixture
grep -vFx "${resource_fixture_rows[0]}" "$release/MANIFEST.md" > "$work/manifest.tmp"
mv "$work/manifest.tmp" "$release/MANIFEST.md"
expect_fail "manifest missing a measured row" "omits a measured resource row"

reset_fixture
grep -F -- "| \`${canonical_images[0]}\` |" "$release/MANIFEST.md" > "$work/row.tmp"
cat "$work/row.tmp" >> "$release/MANIFEST.md"
expect_fail "duplicate manifest image row" "image rows for ${canonical_images[0]}, expected 1"

# The flash figure is read out of the image row by column position, so the
# column order is part of the contract, not a formatting detail.
reset_fixture
sed -i 's/^| image | MCU | clock | flash used \/ reviewed ceiling |/| image | MCU | clock | flash |/' \
	"$release/MANIFEST.md"
expect_fail "reordered image table header" "expected image table header"

reset_fixture
grep -vFx '## Resources' "$release/MANIFEST.md" > "$work/manifest.tmp"
mv "$work/manifest.tmp" "$release/MANIFEST.md"
expect_fail "manifest without the resources section" "measured resources section"

# --- the published programming commands --------------------------------------
# Nothing checked this section before. Each control below is one of the four
# ways v0.9.11's published block was wrong, plus the ways a future producer
# could make it wrong quietly.
reset_fixture
grep -vFx '### Per-image commands' "$release/MANIFEST.md" > "$work/manifest.tmp"
mv "$work/manifest.tmp" "$release/MANIFEST.md"
expect_fail "manifest without the per-image command block" \
	"does not carry the ### Per-image commands section"

reset_fixture
flash_victim=""
for image in "${canonical_images[@]}"; do
	case "$image" in
		*-pic12f675-*) continue ;;
		*) flash_victim=$image; break ;;
	esac
done
[ -n "$flash_victim" ] || fail "the canonical image set contains no non-PIC12F675 image"
flash_victim_command=$(fixture_flash_command "$flash_victim")
grep -vFx "$flash_victim_command" "$release/MANIFEST.md" > "$work/manifest.tmp"
mv "$work/manifest.tmp" "$release/MANIFEST.md"
expect_fail "manifest missing one image's command" \
	"names $flash_victim in the command block and publishes no command for it"

# The v0.9.11 defect itself: the source-checkout alternative appended to a
# download command as parenthesised prose, inside the fenced block.
reset_fixture
sed -i "s|^${flash_victim_command}\$|${flash_victim_command}   (or: make fixture-program VARIANT=x)|" \
	"$release/MANIFEST.md"
expect_fail "appended prose inside the command block" \
	"programming commands that are not valid shell"

# The other v0.9.11 defect: a placeholder that bash reads as a redirection, so
# the option silently disappears from the argv instead of failing.
reset_fixture
sed -i "s|^${flash_victim_command}\$|avrdude -c <prog> -p fixture -U lfuse:w:0x5a:m -U hfuse:w:0xf9:m -U flash:w:${flash_victim}:i|" \
	"$release/MANIFEST.md"
expect_fail "unresolved placeholder in a published command" \
	"carries an unresolved placeholder"

reset_fixture
sed -i "s|^${flash_victim_command}\$|make fixture-program VARIANT=fixture ${flash_victim}|" \
	"$release/MANIFEST.md"
expect_fail "published command that needs a checkout" \
	"invokes make; a downloaded release ships no Makefile"

# The fuse bytes and the command are two renderings of one design value.
reset_fixture
sed -i "s|^${flash_victim_command}\$|${flash_victim_command/lfuse:w:0x5a:m/lfuse:w:0xff:m}|" \
	"$release/MANIFEST.md"
expect_fail "command that writes a fuse the manifest does not publish" \
	"omits lfuse=0x5a, which its own Images row publishes"

# Still names the image, still valid shell -- and writes it in a format that is
# not the intel-hex the release ships.
reset_fixture
sed -i "s|^${flash_victim_command}\$|${flash_victim_command/:i/:a}|" \
	"$release/MANIFEST.md"
expect_fail "command that writes no image" \
	"does not write that image to flash"

# A PIC write with no readback looks exactly like one with a readback.
reset_fixture
flash_pic_victim=""
for image in "${canonical_images[@]}"; do
	case "$image" in
		*-pic10f320-*) flash_pic_victim=$image; break ;;
	esac
done
[ -n "$flash_pic_victim" ] || fail "the canonical image set contains no PIC10F320 image"
flash_pic_command=$(fixture_flash_command "$flash_pic_victim")
sed -i "s|^${flash_pic_command}\$|${flash_pic_command/ -Y/}|" "$release/MANIFEST.md"
expect_fail "PIC command with no verify pass" "performs no verify pass"

# Naming the expected image in a comment does not make it the image pk2cmd
# reads. The sole -F operand is the programming operation's authority.
reset_fixture
sed -i "s|^${flash_pic_command}\$|pk2cmd -Pfixture -Fwrong-image.hex -M -Y -R # ${flash_pic_victim}|" \
	"$release/MANIFEST.md"
expect_fail "PIC command whose expected image appears only in inert text" \
	"does not select $flash_pic_victim as its sole -F image operand"

# The part that must not appear. A per-image shortcut for it is the defect the
# guarded transaction exists to prevent.
reset_fixture
flash_guarded=""
for image in "${canonical_images[@]}"; do
	case "$image" in
		*-pic12f675-*) flash_guarded=$image; break ;;
	esac
done
[ -n "$flash_guarded" ] || fail "the canonical image set contains no PIC12F675 image"
sed -i "s|^# ${flash_victim}\$|# ${flash_guarded}\\npk2cmd -Pfixture -F${flash_guarded} -M -Y -R\\n\\n# ${flash_victim}|" \
	"$release/MANIFEST.md"
expect_fail "raw per-image PIC12F675 write" \
	"publishes a raw per-image write for $flash_guarded"

reset_fixture
sed -i "s|^# ${flash_victim}\$|# bypass-notmine-cd4053_simple.hex\\navrdude -c usbtiny -p fixture -U flash:w:bypass-notmine-cd4053_simple.hex:i\\n\\n# ${flash_victim}|" \
	"$release/MANIFEST.md"
expect_fail "command for an image this release does not ship" \
	"which this release does not ship"

# The variant is not a question to ask the reader; the image answers it.
reset_fixture
sed -i 's|^make fixture-program VARIANT=.*$|make fixture-program VARIANT=not_the_variant|' \
	"$release/MANIFEST.md"
expect_fail "source-checkout command selecting another variant" \
	"does not select its own variant"

reset_fixture
sed -i 's|^make fixture-program VARIANT=|fixture-program VARIANT=|' "$release/MANIFEST.md"
expect_fail "source-checkout command that is not a make invocation" \
	"is not a make invocation"

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

# Express is publishable without --allow-dry-run, on its own soak floor, and
# only while the recorded mode and the human-readable banner say the same thing.
reset_fixture express 3600000 60000 0
expect_pass "express qualification at the 1-h floor"

reset_fixture express 86400000 60000 0
expect_pass "express qualification above its floor"

reset_fixture express 3599999 60000 0
expect_fail "short express soak" "below 3600000"

reset_fixture express 3600000 60000 1
expect_fail "dirty express qualification" "source_dirty=0"

reset_fixture express 3600000 60000 0
sed -i '/EXPRESS QUALIFICATION -- SHORTENED SOAK/d' "$release/MANIFEST.md"
expect_fail "express manifest without its banner" "missing its shortened-soak banner"

reset_fixture production 86400000 60000 0
sed -i '2i > **EXPRESS QUALIFICATION -- SHORTENED SOAK.** Every gate below ran in full; the parallel soak ran 1.0 h per combination instead of 24 h.' \
	"$release/MANIFEST.md"
expect_fail "production manifest carrying the express banner" \
	"production MANIFEST.md contains the express banner"

# --- the per-release README, which nothing read until QUALIFICATION format=4 --
# It is the first file a recipient opens and it makes the same two claims the
# manifest does: which release this is, and whether the soak was shortened. Held
# to the same authority, in both directions, for the same reason.
reset_fixture
rm -f "$release/README.md"
expect_fail "missing per-release README" "README.md is missing"

reset_fixture
rm -f "$release/README.md"
printf 'real readme\n' > "$release/real-readme"
ln -s real-readme "$release/README.md"
expect_fail "symlink per-release README" "README.md is missing"

reset_fixture
sed -i '1s/.*/# v99.0.1/' "$release/README.md"
reseal_provenance
expect_fail "README naming another release" \
	"README.md heading does not match QUALIFICATION version"

reset_fixture express 3600000 60000 0
sed -i '/EXPRESS QUALIFICATION -- SHORTENED SOAK/d' "$release/README.md"
reseal_provenance
expect_fail "express README without its banner" \
	"express README.md is missing its shortened-soak banner"

reset_fixture production 86400000 60000 0
sed -i '2i > **EXPRESS QUALIFICATION -- SHORTENED SOAK.** Every gate below ran in full; the parallel soak ran 1.0 h per combination instead of 24 h.' \
	"$release/README.md"
reseal_provenance
expect_fail "production README carrying the express banner" \
	"production README.md contains the express banner"

reset_fixture production 86400000 60000 0
sed -i '2i > **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.' \
	"$release/README.md"
reseal_provenance
expect_fail "production README carrying the dry-run banner" \
	"production README.md contains the dry-run banner"

reset_fixture dry-run 60000 60000 1
sed -i '/DRY RUN -- NOT A VALIDATED RELEASE/d' "$release/README.md"
reseal_provenance
expect_fail "dry-run README without its warning" \
	"dry-run README.md is missing its warning banner" --allow-dry-run

# --- the toolchain table, which was authored prose until format=5 -------------
# Fifteen rows of compiler and analyzer versions with no machine authority
# behind them. A wrong version there is a provenance error, and until this
# binding existed it passed every gate.
# A missing toolchain.txt is caught by the canonical evidence-set comparison,
# which is the right authority for "a required evidence file is absent" and
# runs before anything reads the file.
reset_fixture
rm -f "$release/evidence/toolchain.txt"
expect_fail "missing toolchain evidence" \
	"retained evidence does not exactly match RELEASE_EVIDENCE_FILES"

reset_fixture
rm -f "$release/evidence/toolchain.txt"
printf 'elsewhere\n' > "$release/evidence/real-toolchain"
ln -s real-toolchain "$release/evidence/toolchain.txt"
expect_fail "symlinked toolchain evidence" \
	"evidence file is empty or not regular: toolchain.txt"

reset_fixture
printf 'appended\n' >> "$release/evidence/toolchain.txt"
expect_fail "toolchain evidence edited after recording" \
	"retained toolchain evidence digest does not match QUALIFICATION"

# The table loses a row the record still claims. The digests all still agree --
# only the row-by-row comparison sees it.
reset_fixture
sed -i '/^| fixture-tool-7 | 1.7.0 |$/d' "$release/MANIFEST.md"
expect_fail "recorded tool missing from the rendered table" \
	"MANIFEST.md toolchain table omits the recorded row for fixture-tool-7"

# A version edited in place. The row count still matches; the content does not.
reset_fixture
sed -i 's/^| fixture-tool-3 | 1.3.0 |$/| fixture-tool-3 | 9.9.9 |/' \
	"$release/MANIFEST.md"
expect_fail "rendered tool version edited after rendering" \
	"MANIFEST.md toolchain table omits the recorded row for fixture-tool-3"

# A tool the record does not justify. Every recorded row is still present, so
# only counting the table's own rows catches this one.
reset_fixture
sed -i 's/^| fixture-tool-1 | 1.1.0 |$/| fixture-tool-1 | 1.1.0 |\n| smuggled-tool | 0.0.1 |/' \
	"$release/MANIFEST.md"
expect_fail "unrecorded tool added to the rendered table" \
	"MANIFEST.md toolchain table has 17 rows for 15 recorded tools"

reset_fixture
sed -i 's/^TOOLCHAIN_RESULT format=1 status=pass rows=15/TOOLCHAIN_RESULT format=1 status=pass rows=14/' \
	"$release/evidence/toolchain.txt"
refresh_toolchain_digest
expect_fail "toolchain result miscounts its own rows" \
	"toolchain evidence has no exact source-bound complete result"

reset_fixture
sed -i 's/^TOOLCHAIN format=1 source_commit=.*/TOOLCHAIN format=1 source_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
	"$release/evidence/toolchain.txt"
refresh_toolchain_digest
expect_fail "toolchain evidence bound to another commit" \
	"toolchain evidence has no source-bound header record"

reset_fixture
printf 'a-tool-with-no-version\n' >> "$release/evidence/toolchain.txt"
refresh_toolchain_digest
expect_fail "toolchain record without a version" \
	"malformed toolchain evidence record"

# --- the evidence index, and the logs it made checkable -----------------------
# Thirteen retained files -- every build log, every target-test log, 62% of the
# evidence tree by bytes -- were checked for their name and their non-emptiness
# and nothing else until format=6; format 7 seals their exact operation payload.
# These controls hold the index to the Makefile and to the files, in both
# directions, and hold each of the thirteen to its own record. A missing INDEX is
# caught by the canonical evidence-set comparison, which runs first and is the
# right authority for an absent evidence file.
#
# The controls below corrupt the index and re-pin its digest WITHOUT
# re-rendering it. Regenerating would rewrite the edit away and leave a control
# that passes because it no longer tests anything.
reset_fixture
printf 'appended after recording\n' >> "$release/evidence/INDEX"
expect_fail "evidence index edited after recording" \
	"evidence index digest does not match QUALIFICATION"

reset_fixture
sed -i "s/^EVIDENCE_INDEX format=2 source_commit=$sha$/EVIDENCE_INDEX format=2 source_commit=$other_sha/" \
	"$release/evidence/INDEX"
reseal_evidence_index
expect_fail "evidence index bound to another commit" \
	"evidence index has no source-bound header record"

reset_fixture
sed -i 's/^EVIDENCE_INDEX_RESULT format=2 status=pass members=36 /EVIDENCE_INDEX_RESULT format=2 status=pass members=35 /' \
	"$release/evidence/INDEX"
reseal_evidence_index
expect_fail "evidence index miscounting its own members" \
	"evidence index has no exact source-bound complete result"

# The index calls a member something the Makefile does not. This is why the role
# map is read from the Makefile and not from the index: an index trusted for its
# own vocabulary would agree with itself here.
reset_fixture
sed -i 's/^build-avr-xt\.log\tbuild\t/build-avr-xt.log\tsoak\t/' \
	"$release/evidence/INDEX"
reseal_evidence_index
expect_fail "evidence index mislabels a member's role" \
	"the Makefile declares build"

reset_fixture
sed -i 's/^\(build-avr-xt\.log\tbuild\t\)[0-9]*\t/\19999\t/' \
	"$release/evidence/INDEX"
reseal_evidence_index
expect_fail "evidence index misreports a member's size" \
	"evidence index records build-avr-xt.log as 9999 bytes"

reset_fixture
grep -v "^build-avr-xt\.log$(printf '\t')" "$release/evidence/INDEX" \
	> "$release/evidence/INDEX.tmp"
mv "$release/evidence/INDEX.tmp" "$release/evidence/INDEX"
reseal_evidence_index
expect_fail "evidence index omits a retained file" \
	"evidence index lists 35 members, expected 36"

reset_fixture
sed -i 's/^build-avr-xt\.log\t/not-retained.log\t/' "$release/evidence/INDEX"
reseal_evidence_index
expect_fail "evidence index lists a file the release does not retain" \
	"which is not retained evidence"

reset_fixture
grep "^build-avr-xt\.log$(printf '\t')" "$release/evidence/INDEX" \
	> "$release/evidence/INDEX.row"
cat "$release/evidence/INDEX.row" >> "$release/evidence/INDEX"
rm -f "$release/evidence/INDEX.row"
reseal_evidence_index
expect_fail "evidence index lists a member twice" \
	"evidence index lists build-avr-xt.log twice"

# The index reports a verdict the file does not carry. The member's own bytes are
# untouched, so nothing but this cross-check catches it.
reset_fixture
sed -i 's/^\(build-avr-xt\.log\tbuild\t[0-9]*\t\)EVIDENCE_RESULT format=2 status=pass/\1EVIDENCE_RESULT format=2 status=fail/' \
	"$release/evidence/INDEX"
reseal_evidence_index
expect_fail "evidence index misreports a member's terminal record" \
	"evidence index misreports the terminal record of build-avr-xt.log"

# --- the thirteen operation-sealed, content-bound logs ------------------------
# These corrupt the LOG. restate_index_row puts the row back in step first, using
# the verifier's own derivation, so what fires is the member check under test
# rather than the size or record mismatch on the way to it.
reset_fixture
grep -v '^EVIDENCE_RESULT ' "$release/evidence/build-avr-xt.log" \
	> "$release/evidence/build-avr-xt.log.tmp"
mv "$release/evidence/build-avr-xt.log.tmp" "$release/evidence/build-avr-xt.log"
restate_index_row build-avr-xt.log
expect_fail "retained build log with no terminal record" \
	"build-avr-xt.log carries 0 EVIDENCE_RESULT records"

reset_fixture
grep '^EVIDENCE_RESULT ' "$release/evidence/build-avr-xt.log" \
	> "$release/evidence/build-avr-xt.record"
cat "$release/evidence/build-avr-xt.record" \
	>> "$release/evidence/build-avr-xt.log"
rm -f "$release/evidence/build-avr-xt.record"
restate_index_row build-avr-xt.log
expect_fail "retained build log with two terminal records" \
	"build-avr-xt.log carries 2 EVIDENCE_RESULT records"

# A log kept from an earlier run: the record is well formed and names the right
# file, but it was written against a different commit. Forty hex characters
# replace forty, so the file's size is unchanged and the index still agrees --
# only the commit binding catches this.
reset_fixture
sed -i "s/^\(EVIDENCE_RESULT .*\)source_commit=$sha$/\1source_commit=$other_sha/" \
	"$release/evidence/build-avr-xt.log"
expect_fail "retained build log bound to another commit" \
	"build-avr-xt.log payload digest or result metadata does not match"

# A failing run's log retained as if it had passed. Same length again.
reset_fixture
sed -i 's/^\(EVIDENCE_RESULT format=2 status=\)pass/\1fail/' \
	"$release/evidence/build-avr-xt.log"
expect_fail "retained build log recording a failure" \
	"build-avr-xt.log payload digest or result metadata does not match"

# One log substituted for its neighbour. Both are build logs bound to this same
# commit and this same run, so only the `evidence` field tells them apart.
reset_fixture
sed -i 's/evidence=build-avr-xt\.log/evidence=build-avr-classic.log/' \
	"$release/evidence/build-avr-xt.log"
restate_index_row build-avr-xt.log
expect_fail "retained build log carrying another file's record" \
	"build-avr-xt.log payload digest or result metadata does not match"

# The original defect: replace payload bytes without changing either byte size
# or line count. The stored result and index remain self-consistent;
# only independent payload hashing can reject this.
reset_fixture
sed -i '1s/retained/replaced/' "$release/evidence/build-avr-xt.log"
expect_fail "same-shape retained build log substitution" \
	"build-avr-xt.log payload digest or result metadata does not match"

# Even a syntactically valid digest copied into both authorities is only a claim.
# Re-pin the outer index root and require the verifier to hash the payload.
reset_fixture
sed -i 's/payload_sha256=[0-9a-f]\{64\}/payload_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
	"$release/evidence/build-avr-xt.log"
sed -i '/^build-avr-xt\.log\t/s/payload_sha256=[0-9a-f]\{64\}/payload_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
	"$release/evidence/INDEX"
reseal_evidence_index
expect_fail "self-consistent false payload digest" \
	"build-avr-xt.log payload digest or result metadata does not match"

reset_fixture
sed -i 's/EVIDENCE_RESULT format=2/EVIDENCE_RESULT format=1/' \
	"$release/evidence/build-avr-xt.log"
sed -i '/^build-avr-xt\.log\t/s/EVIDENCE_RESULT format=2/EVIDENCE_RESULT format=1/' \
	"$release/evidence/INDEX"
reseal_evidence_index
expect_fail "length-only evidence result downgrade" \
	"build-avr-xt.log payload digest or result metadata does not match"

# Content appended after the record was written. The line count in the record no
# longer describes the file, which is the whole reason it is recorded.
reset_fixture
printf 'smuggled in after the record\n' >> "$release/evidence/build-avr-xt.log"
restate_index_row build-avr-xt.log
expect_fail "retained build log extended after recording" \
	"build-avr-xt.log EVIDENCE_RESULT is not the final line"

# --- the index digest reaches the manifest and the schema ---------------------
reset_fixture
sed -i '/^evidence_index_sha256=/d' "$release/QUALIFICATION"
reseal_provenance
expect_fail "qualification without an evidence index digest" \
	"missing QUALIFICATION key: evidence_index_sha256"

reset_fixture
sed -i 's/^evidence_index_sha256=.*/evidence_index_sha256=not-a-digest/' \
	"$release/QUALIFICATION"
reseal_provenance
expect_fail "malformed evidence index digest" \
	"evidence_index_sha256 is not a lowercase SHA-256"

reset_fixture
sed -i 's/^- \*\*Evidence index:\*\*.*/- **Evidence index:** `evidence\/INDEX` (SHA-256 `0000000000000000000000000000000000000000000000000000000000000000`), 36 retained files by role and terminal record/' \
	"$release/MANIFEST.md"
reseal_provenance
expect_fail "manifest disagrees about the evidence index" \
	"MANIFEST.md evidence index digest does not match QUALIFICATION"

# --- the signature has to reach the provenance --------------------------------
# Every release through v0.9.11 signed its images and left QUALIFICATION,
# MANIFEST.md and README.md outside the checksum list. These four hold the new
# contract from both sides: the entry has to be there, and it has to be the
# digest of the file that is actually there.
reset_fixture
grep -v '  QUALIFICATION$' "$release/SHA256SUMS" > "$release/SHA256SUMS.tmp"
mv "$release/SHA256SUMS.tmp" "$release/SHA256SUMS"
expect_fail "QUALIFICATION outside the signed checksum list" \
	"QUALIFICATION is not covered by SHA256SUMS"

reset_fixture
grep -v '  MANIFEST\.md$' "$release/SHA256SUMS" > "$release/SHA256SUMS.tmp"
mv "$release/SHA256SUMS.tmp" "$release/SHA256SUMS"
expect_fail "MANIFEST.md outside the signed checksum list" \
	"MANIFEST.md is not covered by SHA256SUMS"

reset_fixture
grep -v '  README\.md$' "$release/SHA256SUMS" > "$release/SHA256SUMS.tmp"
mv "$release/SHA256SUMS.tmp" "$release/SHA256SUMS"
expect_fail "README.md outside the signed checksum list" \
	"README.md is not covered by SHA256SUMS"

# The edit that the whole change exists to catch: provenance rewritten after
# the release was sealed. Deliberately NOT resealed.
reset_fixture
printf '\nappended after sealing\n' >> "$release/README.md"
expect_fail "provenance edited after sealing" \
	"README.md does not hash to the value SHA256SUMS records for it"

# The manifest gains a paragraph that contradicts nothing the cross-checks
# above read -- the version, mode, commit, digests and banner all still agree.
# Before format=4 this was an undetectable edit to a published release; now the
# only thing that catches it is the digest the release signed for itself.
reset_fixture
printf '\nAn amendment nobody sealed.\n' >> "$release/MANIFEST.md"
expect_fail "manifest gains an unsealed paragraph" \
	"MANIFEST.md does not hash to the value SHA256SUMS records for it"

reset_fixture express 3600000 60000 0
sed -i '2i > **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.' \
	"$release/MANIFEST.md"
expect_fail "express manifest carrying the dry-run banner" \
	"express MANIFEST.md contains the dry-run banner"

reset_fixture
sed -i 's/^release_mode=production$/release_mode=turbo/' "$release/QUALIFICATION"
sed -i 's/^- \*\*Release mode:\*\* production$/- **Release mode:** turbo/' \
	"$release/MANIFEST.md"
expect_fail "unknown release mode" "invalid release_mode: turbo"

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
sed -i '/^TEST_LONG_RESULT /d' "$release/evidence/test-long.summary.txt"
expect_fail "missing test-long result" "exactly one TEST_LONG_RESULT"

reset_fixture
test_long_record=$(grep '^TEST_LONG_RESULT ' \
	"$release/evidence/test-long.summary.txt")
printf '%s\n' "$test_long_record" >> "$release/evidence/test-long.summary.txt"
expect_fail "duplicate test-long result" "exactly one TEST_LONG_RESULT"

reset_fixture
sed -i 's/status=pass/status=fail/' "$release/evidence/test-long.summary.txt"
expect_fail "failed test-long result" "no exact source-bound passing test-long result"

reset_fixture
sed -i "s/source_commit=$sha/source_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" \
	"$release/evidence/test-long.summary.txt"
expect_fail "wrong-source test-long result" "no exact source-bound passing test-long result"

reset_fixture
printf 'extra\n' > "$release/evidence/.hidden"
expect_fail "hidden extra evidence" "invalid name"

reset_fixture
printf 'retired split evidence\n' > "$release/evidence/pic12f675-test.log"
expect_fail "retired split PIC12F675 evidence" \
	"does not exactly match RELEASE_EVIDENCE_FILES"

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

[ "${#evidence_names[@]}" -eq 37 ] \
	|| fail "canonical release evidence set has ${#evidence_names[@]} entries, expected 37"
for required in pic12f675-qualification.log pic12f675-qualified-matrix.json \
		toolchain.txt; do
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
# MANIFEST.md is published verbatim as the GitHub Release body, where a
# repo-relative link does not resolve. Pin all three properties of the fix --
# absolute base, tag-pinned path, and the absence of the old relative form --
# rather than one exact source line, so reformatting the generator cannot
# silently drop the assertion.
grep -Eq '^REPO_URL=https://github\.com/matt-garman/mcu-bypass-firmware$' \
	"$RELEASE" \
	|| fail "release manifest link base REPO_URL is not the canonical absolute project URL"
grep -Fq 'Full detail: [DESIGN_DOCUMENTATION.adoc](%s/blob/%s/DESIGN_DOCUMENTATION.adoc#pic10f320-architecture)' \
	"$RELEASE" \
	|| fail "release manifest special-case link is not pinned to its version tag"
grep -Fq '"$REPO_URL" "$VERSION"' \
	"$RELEASE" \
	|| fail "release manifest special-case link does not interpolate REPO_URL and VERSION"
! grep -Eq '\]\(\.\./\.\./(docs/pic10f320_special_case\.md|DESIGN_DOCUMENTATION\.adoc)' "$RELEASE" \
	|| fail "release manifest special-case link regressed to a repo-relative path"
grep -Fq '[[pic10f320-architecture]]' "$ROOT/DESIGN_DOCUMENTATION.adoc" \
	|| fail "release manifest special-case link targets an anchor the design document does not define"
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
printf '%s\t%s\t%s\n' \
	'bypass-attiny13a-cd4053_simple.hex' avrdude-isp \
	'avrdude -c test-programmer -p t13 -U flash:w:bypass-attiny13a-cd4053_simple.hex:i' \
	'bypass-pic10f322-cd4053_simple.hex' pk2cmd \
	'pk2cmd -PPIC10F322 -Fbypass-pic10f322-cd4053_simple.hex -M -Y -R' \
	'bypass-pic10f322-cd4053_simple.hex' make-source \
	'make pic10f322-program VARIANT=cd4053_simple' \
	> "$flashing_fixture"
helper_commands="$work/rendered-pic12f675-helper.sh"
helper_recovery="$work/rendered-pic12f675-helper-recovery.sh"
release_render_flashing "$flashing_fixture" v0.9.9 \
	test-programmer serialupdi /dev/ttyUSB0 > "$flashing"
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
grep -Fq ': # no flash_row for PIC12F675' "$RELEASE" \
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

printf '%s\t%s\t%s\n' 'bypass-pic12f675-cd4053_simple.hex' pk2cmd \
	'pk2cmd -PPIC12F675 -Fbypass-pic12f675-cd4053_simple.hex -M -Y -R' > "$flashing_fixture"
if release_render_flashing "$flashing_fixture" v0.9.9 \
		test-programmer serialupdi /dev/ttyUSB0 >/dev/null; then
	fail "assembled flashing renderer accepted a per-image PIC12F675 writer command"
fi
checks=$((checks + 1))

# The renderer's own refusals. The producer checks these rows in far more
# detail, but a page rendered from rows nobody checked would still be wrong,
# and each shape below reached a published release or nearly did.
render_flash_reject() {
	local label=$1 image=$2 profile=$3 command=$4
	printf '%s\t%s\t%s\n' "$image" "$profile" "$command" > "$flashing_fixture"
	if release_render_flashing "$flashing_fixture" v0.9.9 \
			test-programmer serialupdi /dev/ttyUSB0 >/dev/null 2>&1; then
		fail "assembled flashing renderer accepted $label"
	fi
	checks=$((checks + 1))
}
render_flash_reject "an unresolved placeholder" \
	bypass-attiny13a-cd4053_simple.hex avrdude-isp \
	'avrdude -c <prog> -p t13 -U flash:w:bypass-attiny13a-cd4053_simple.hex:i'
render_flash_reject "prose appended to an executable line" \
	bypass-attiny13a-cd4053_simple.hex avrdude-isp \
	'avrdude -c usbtiny -p t13 -U flash:w:bypass-attiny13a-cd4053_simple.hex:i   (or: make attiny13a-program)'
render_flash_reject "a download command that needs a checkout" \
	bypass-attiny13a-cd4053_simple.hex avrdude-isp \
	'make attiny13a-program VARIANT=cd4053_simple'
render_flash_reject "a command filed under an image it does not name" \
	bypass-attiny13a-cd4053_simple.hex avrdude-isp \
	'avrdude -c usbtiny -p t13 -U flash:w:bypass-attiny45-cd4053_simple.hex:i'
render_flash_reject "a source-checkout command for another variant" \
	bypass-pic10f322-cd4053_simple.hex make-source \
	'make pic10f322-program VARIANT=tq2_l2_5v_relay'
render_flash_reject "an unknown programming profile" \
	bypass-pic10f322-cd4053_simple.hex ipecmd-pk3 \
	'ipecmd -TPPK3 -PPIC10F322 -M -Fbypass-pic10f322-cd4053_simple.hex'
render_flash_reject "a page with no runnable command at all" \
	bypass-pic10f322-cd4053_simple.hex make-source \
	'make pic10f322-program VARIANT=cd4053_simple'

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
# The signed manifest is published verbatim as the GitHub Release body, so the
# substrate claim it makes about the output lanes is read by people with no
# repository context. Every lane it names is a simulator lane (yasimavr, gpsim)
# observing MODELED pins, and the generated evidence said "physical-output
# checks" long after the static documents were corrected. Both directions are
# pinned: the modeled wording must be present, and the retired claim must not
# reappear under any spelling.
grep -Fq 'modeled-pin output checks' "$rendered_manifest" \
	|| fail "rendered validation prose does not call the simulator output lanes modeled-pin checks"
checks=$((checks + 1))
for required in '`test-long` retention:' 'one source-bound `TEST_LONG_RESULT` PASS record' \
		'the complete transcript is transient diagnostic output' \
		'hosted job log is subject to platform retention and is not release evidence'; do
	grep -Fq "$required" "$rendered_manifest" \
		|| fail "rendered validation prose omits test-long retention policy: $required"
done
checks=$((checks + 1))
if grep -Eqi 'physical[- ](output|pin|port)' "$rendered_manifest"; then
	fail "rendered validation prose claims physical output evidence for simulator lanes"
fi
checks=$((checks + 1))
# The toolchain table renders from evidence as of QUALIFICATION format=5, so
# these attributions are exercised through that renderer against a synthetic
# record file. The claim they protect is unchanged and is the reason the labels
# read the way they do: one XC8 and one DFP serve BOTH the PIC10F322 and the
# PIC12F675, and a table that names only one of the two parts tells a reader
# their device was built with a compiler nobody recorded.
rendered_toolchain="$work/rendered-toolchain.md"
renderer_sha=0000000000000000000000000000000000000000
toolchain_records="$work/toolchain-records.txt"
{
	printf 'TOOLCHAIN format=1 source_commit=%s\n' "$renderer_sha"
	printf '%s\t%s\n' \
		"PIC10F322/PIC12F675 XC8 (\`PIC_CC=$selected_pic_cc\`)" 'XC8 shared version' \
		"PIC10F320 XC8 (\`PIC10F320_CC=$selected_pic320_cc\`)" 'XC8 PIC10F320 version' \
		'PIC10F322/PIC12F675 DFP (`PIC_DFP`)' "$selected_pic_dfp" \
		'PIC10F320 DFP (`PIC10F320_DFP`)' "$selected_pic320_dfp"
	printf 'TOOLCHAIN_RESULT format=1 status=pass rows=4 source_commit=%s\n' \
		"$renderer_sha"
} > "$toolchain_records"
release_render_toolchain_table "$toolchain_records" > "$rendered_toolchain" \
	|| fail "could not render the toolchain table from its records"
grep -Fq "| PIC10F322/PIC12F675 XC8 (\`PIC_CC=$selected_pic_cc\`) | XC8 shared version |" \
	"$rendered_toolchain" \
	|| fail "rendered toolchain table does not attribute shared XC8 to PIC10F322 and PIC12F675"
grep -Fq "| PIC10F322/PIC12F675 DFP (\`PIC_DFP\`) | $selected_pic_dfp |" \
	"$rendered_toolchain" \
	|| fail "rendered toolchain table does not attribute shared DFP to PIC10F322 and PIC12F675"
# The header is emitted by the renderer too, so the table has one producer.
grep -Fxq '| tool | version |' "$rendered_toolchain" \
	|| fail "rendered toolchain table omits its header row"
# The TOOLCHAIN and TOOLCHAIN_RESULT records are metadata, not tools, and must
# not appear as rows.
if grep -q 'TOOLCHAIN' "$rendered_toolchain"; then
	fail "rendered toolchain table leaks a machine record as a tool row"
fi
[ "$(grep -c '^| .* | .* |$' "$rendered_toolchain")" -eq 5 ] \
	|| fail "rendered toolchain table has the wrong row count for 4 records"
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
# The express message must name its own mode AND carry the real soak hours it
# was rendered with: the description and the validation list are the same claim.
release_render_commit_message v0.9.9 express abc1234 21 1.0 \
	> "$rendered_commit"
grep -Fq 'Prebuilt firmware images, express-qualified (every gate in full, shortened soak) for v0.9.9.' \
	"$rendered_commit" \
	|| fail "rendered express commit message has the wrong release mode"
grep -Fq '+ 1.0-h parallel soak of every release soak combination' "$rendered_commit" \
	|| fail "rendered express commit message does not carry its actual soak duration"
if release_render_commit_message v0.9.9 invalid abc1234 21 24 >/dev/null; then
	fail "release commit-message renderer accepted an invalid release mode"
fi
checks=$((checks + 1))

printf 'release qualification validation: %d checks, 0 failures\n' "$checks"
