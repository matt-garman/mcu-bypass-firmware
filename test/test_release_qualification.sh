#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-release-qualification.sh"
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

read -r -a soak_names <<<"$(make -s -C "$ROOT" print-RELEASE_SOAK_NAMES)"
read -r -a evidence_names <<<"$(make -s -C "$ROOT" print-RELEASE_EVIDENCE_FILES)"

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

[ "${#soak_names[@]}" -eq 12 ] \
	|| fail "canonical release soak set has ${#soak_names[@]} entries, expected 12"
overridden=$(make -s -C "$ROOT" RELEASE_SOAK_NAMES=bad print-RELEASE_SOAK_NAMES)
[ "$overridden" = "${soak_names[*]}" ] \
	|| fail "command-line override changed canonical RELEASE_SOAK_NAMES"
for required in avr_cd4053_t85 pic_relay pic320_tq2-relay; do
	[[ " ${soak_names[*]} " == *" $required "* ]] \
		|| fail "canonical release soak set is missing $required"
done
checks=$((checks + 1))

[ "${#evidence_names[@]}" -eq 22 ] \
	|| fail "canonical release evidence set has ${#evidence_names[@]} entries, expected 22"
overridden=$(make -s -C "$ROOT" RELEASE_EVIDENCE_FILES=bad print-RELEASE_EVIDENCE_FILES)
[ "$overridden" = "${evidence_names[*]}" ] \
	|| fail "command-line override changed canonical RELEASE_EVIDENCE_FILES"
checks=$((checks + 1))

for wiring in \
	'SOAK_COMBINATION_NAME="$name"' \
	'PIC_SOAK_COMBINATION_NAME="$name"' \
	'PIC320_SOAK_COMBINATION_NAME="$name"'; do
	grep -Fq "$wiring" "$ROOT/scripts/make-release.sh" \
		|| fail "release producer is missing soak identity wiring: $wiring"
done
grep -Fq 'scripts/verify-release-qualification.sh "${qualification_args[@]}" "$OUTPUT_DIR" "$VERSION"' \
	"$ROOT/scripts/make-release.sh" \
	|| fail "release producer does not self-verify staged qualification"
grep -Fq 'scripts/verify-release-qualification.sh "$dir" "$tag"' \
	"$ROOT/.github/workflows/release.yml" \
	|| fail "tag workflow does not verify committed release qualification"
grep -Fq '"$dir/QUALIFICATION"' "$ROOT/.github/workflows/release.yml" \
	|| fail "tag workflow does not retain QUALIFICATION for publication"
grep -Fq 'a staged PIC image differs from the image exercised by the soak' \
	"$ROOT/scripts/make-release.sh" \
	|| fail "release producer does not bind staged PIC images to soak inputs"
checks=$((checks + 1))

printf 'release qualification validation: %d checks, 0 failures\n' "$checks"
