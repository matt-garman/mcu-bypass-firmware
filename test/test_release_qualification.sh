#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-release-qualification.sh"
RENDER="$ROOT/scripts/release-documentation.sh"
RELEASE=${RELEASE:-$ROOT/scripts/make-release.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-qualification.XXXXXX")
release="$work/release"
sha=0123456789abcdef0123456789abcdef01234567
version=v99.0.0
checks=0
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -r "$RENDER" ] || fail "release documentation renderer is missing"
# shellcheck source=../scripts/release-documentation.sh
source "$RENDER"
for function in release_render_scope release_render_validation \
		release_render_pic_toolchain_rows release_render_reproduction_commands \
		release_render_commit_message; do
	declare -F "$function" >/dev/null \
		|| fail "release documentation renderer omitted $function"
done
checks=$((checks + 1))

for wiring in \
	'source "$REPO_ROOT/scripts/release-documentation.sh"' \
	$'\trelease_render_scope' \
	$'\trelease_render_validation "$hours"' \
	$'\trelease_render_pic_toolchain_rows "$PIC_CC" "$TC_XC8_322"' \
	$'\t\t"$PIC10F320_CC" "$TC_XC8_320" "$PIC_DFP" "$PIC10F320_DFP"' \
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
	<<<"$(make -s --no-print-directory -C "$ROOT" print-RELEASE_SOAK_NAMES)"
read -r -a evidence_names \
	<<<"$(make -s --no-print-directory -C "$ROOT" print-RELEASE_EVIDENCE_FILES)"

reset_fixture() {
	local mode=${1:-production}
	local duration=${2:-86400000}
	local liveness=${3:-60000}
	local dirty=${4:-0}
	local expected_checks=$((duration / liveness)) name file
	rm -rf "$release"
	mkdir -p "$release/evidence"
	for file in "${evidence_names[@]}"; do
		printf 'retained evidence: %s\n' "$file" > "$release/evidence/$file"
	done
	for name in "${soak_names[@]}"; do
		cat > "$release/evidence/soak-$name.log" <<EOF
SOAK START: synthetic qualification fixture
SOAK PASS: $duration ms (fixture) simulated.
SOAK_RESULT format=1 status=pass combination=$name duration_ms=$duration liveness_interval_ms=$liveness checks=$expected_checks failures=0 watchdog_failures=0 liveness_failures=0
EOF
	done
	cat > "$release/QUALIFICATION" <<EOF
format=1
version=$version
release_mode=$mode
source_commit=$sha
source_dirty=$dirty
soak_duration_ms=$duration
soak_liveness_interval_ms=$liveness
soak_combination_count=${#soak_names[@]}
EOF
	{
		printf '# Firmware release %s\n\n' "$version"
		[ "$mode" != dry-run ] \
			|| printf '> **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.\n\n'
		printf -- '- **Release mode:** %s\n' "$mode"
		printf -- '- **Source commit:** `%s`\n' "$sha"
		printf -- '- **Soak duration per combination:** %s ms\n' "$duration"
		printf -- '- **Soak combinations:** %s\n' "${#soak_names[@]}"
	} > "$release/MANIFEST.md"
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
printf 'format=1\n' >> "$release/QUALIFICATION"
expect_fail "duplicate qualification key" "duplicate QUALIFICATION key"

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
		pic10f320-test pic10f320-test-target-variants \
		pic12f675-test pic12f675-test-target-variants; do
	grep -Fq "\`make $target\`" "$rendered_manifest" \
		|| fail "rendered validation prose omits $target"
done
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
for target in pic12f675-test pic12f675-test-target-variants; do
	grep -Fq "make $target" "$rendered_commit" \
		|| fail "rendered release commit message omits $target"
done
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
