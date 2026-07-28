#!/usr/bin/env bash
# Verify the retained local release qualification before tag CI publishes it.
# This does not rerun the 24-hour soak. It fails unless the committed evidence
# has the exact canonical inventory and every soak log carries one complete,
# machine-readable result matching the producer's qualification metadata.
set -euo pipefail
LC_ALL=C
export LC_ALL

MIN_RELEASE_SOAK_MS=86400000
MAX_SOAK_DURATION_MS=4294967294
allow_dry_run=0

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "${1:-}" = --allow-dry-run ]; then
	allow_dry_run=1
	shift
fi
if [ "$#" -ne 2 ]; then
	printf 'usage: %s [--allow-dry-run] <release-dir> <expected-version>\n' "$0" >&2
	exit 2
fi

release_dir=$1
expected_version=$2
[[ "$expected_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
	|| die "invalid expected release version: $expected_version"
[ -d "$release_dir" ] || die "release directory not found: $release_dir"
release_dir=$(cd "$release_dir" && pwd -P) \
	|| die "cannot resolve release directory: $release_dir"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) \
	|| die "cannot locate repository root"
command -v make >/dev/null 2>&1 \
	|| die "make is required to read the canonical release qualification set"

qualification="$release_dir/QUALIFICATION"
manifest="$release_dir/MANIFEST.md"
evidence_dir="$release_dir/evidence"
[ -f "$qualification" ] && [ ! -L "$qualification" ] && [ -s "$qualification" ] \
	|| die "QUALIFICATION is missing, empty, or not a regular file"
[ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -s "$manifest" ] \
	|| die "MANIFEST.md is missing, empty, or not a regular file"
[ -d "$evidence_dir" ] && [ ! -L "$evidence_dir" ] \
	|| die "evidence is missing or not a real directory"

# Strict key=value schema. Never source release metadata: it is committed input
# to a privileged workflow and must remain data, not shell code.
declare -A q=()
required_keys=(format version release_mode source_commit source_dirty \
	soak_duration_ms soak_liveness_interval_ms soak_combination_count)
line_no=0
while IFS= read -r line || [ -n "$line" ]; do
	line_no=$((line_no + 1))
	[[ "$line" != *$'\r'* ]] \
		|| die "QUALIFICATION line $line_no contains a carriage return"
	[[ "$line" =~ ^([a-z][a-z0-9_]*)=([A-Za-z0-9._-]+)$ ]] \
		|| die "malformed QUALIFICATION line $line_no: $line"
	key=${BASH_REMATCH[1]}
	value=${BASH_REMATCH[2]}
	case " ${required_keys[*]} " in
		*" $key "*) ;;
		*) die "unknown QUALIFICATION key: $key" ;;
	esac
	[ "${q[$key]+set}" != set ] || die "duplicate QUALIFICATION key: $key"
	q[$key]=$value
done < "$qualification"
for key in "${required_keys[@]}"; do
	[ "${q[$key]+set}" = set ] || die "missing QUALIFICATION key: $key"
done
[ "${#q[@]}" -eq "${#required_keys[@]}" ] \
	|| die "QUALIFICATION does not contain the exact required schema"

[ "${q[format]}" = 1 ] || die "unsupported QUALIFICATION format: ${q[format]}"
[ "${q[version]}" = "$expected_version" ] \
	|| die "QUALIFICATION version ${q[version]} does not match $expected_version"
[[ "${q[source_commit]}" =~ ^[0-9a-f]{40}$ ]] \
	|| die "QUALIFICATION source_commit is not a full lowercase SHA-1"

case "${q[release_mode]}" in
	production)
		[ "${q[source_dirty]}" = 0 ] \
			|| die "production qualification must record source_dirty=0"
		;;
	dry-run)
		[ "$allow_dry_run" -eq 1 ] \
			|| die "dry-run qualification is not publishable"
		case "${q[source_dirty]}" in 0|1) ;; *) die "invalid source_dirty value" ;; esac
		;;
	*) die "invalid release_mode: ${q[release_mode]}" ;;
esac

for key in soak_duration_ms soak_liveness_interval_ms soak_combination_count; do
	[[ "${q[$key]}" =~ ^[1-9][0-9]*$ ]] \
		|| die "$key must be a positive canonical decimal integer"
done
duration=${q[soak_duration_ms]}
liveness=${q[soak_liveness_interval_ms]}
if [ "${#duration}" -gt "${#MAX_SOAK_DURATION_MS}" ] \
		|| { [ "${#duration}" -eq "${#MAX_SOAK_DURATION_MS}" ] \
			&& [[ "$duration" > "$MAX_SOAK_DURATION_MS" ]]; }; then
	die "soak_duration_ms exceeds $MAX_SOAK_DURATION_MS"
fi
if [ "${q[release_mode]}" = production ] \
		&& { [ "${#duration}" -lt "${#MIN_RELEASE_SOAK_MS}" ] \
			|| { [ "${#duration}" -eq "${#MIN_RELEASE_SOAK_MS}" ] \
				&& [[ "$duration" < "$MIN_RELEASE_SOAK_MS" ]]; }; }; then
	die "production soak_duration_ms is below $MIN_RELEASE_SOAK_MS"
fi
if [ "${#liveness}" -gt "${#duration}" ] \
		|| { [ "${#liveness}" -eq "${#duration}" ] \
			&& [[ "$liveness" > "$duration" ]]; }; then
	die "soak_liveness_interval_ms exceeds soak_duration_ms"
fi
duration_num=$((duration))
liveness_num=$((liveness))
expected_checks=$((duration_num / liveness_num))
[ "$expected_checks" -gt 0 ] || die "qualification would execute zero liveness checks"

canonical_soaks_raw=$(make -s -C "$repo_root" print-RELEASE_SOAK_NAMES) \
	|| die "cannot read RELEASE_SOAK_NAMES from the Makefile"
canonical_evidence_raw=$(make -s -C "$repo_root" print-RELEASE_EVIDENCE_FILES) \
	|| die "cannot read RELEASE_EVIDENCE_FILES from the Makefile"
read -r -a canonical_soaks <<<"$canonical_soaks_raw"
read -r -a canonical_evidence <<<"$canonical_evidence_raw"
[ "${#canonical_soaks[@]}" -gt 0 ] || die "canonical release soak set is empty"
[ "${#canonical_evidence[@]}" -gt 0 ] || die "canonical release evidence set is empty"
[ "${q[soak_combination_count]}" -eq "${#canonical_soaks[@]}" ] \
	|| die "soak_combination_count does not match the canonical set"

validate_canonical_names() {
	local label=$1
	shift
	local name
	declare -A seen=()
	for name in "$@"; do
		[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
			|| die "$label has an invalid name: $name"
		[ "${seen[$name]+set}" != set ] || die "$label has a duplicate name: $name"
		seen[$name]=1
	done
}
validate_canonical_names "canonical release soak set" "${canonical_soaks[@]}"
validate_canonical_names "canonical release evidence set" "${canonical_evidence[@]}"

work=$(mktemp -d "${TMPDIR:-/tmp}/release-qualification.XXXXXX")
trap 'rm -rf "$work"' EXIT
expected_list="$work/expected-evidence"
actual_list="$work/actual-evidence"
printf '%s\n' "${canonical_evidence[@]}" | sort > "$expected_list"
: > "$actual_list"
shopt -s nullglob dotglob
evidence_paths=("$evidence_dir"/*)
shopt -u nullglob dotglob
for path in "${evidence_paths[@]}"; do
	base=${path##*/}
	[[ "$base" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
		|| die "evidence has an invalid name: $base"
	[ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] \
		|| die "evidence file is empty or not regular: $base"
	printf '%s\n' "$base" >> "$actual_list"
done
sort -o "$actual_list" "$actual_list"
if ! diff -u "$expected_list" "$actual_list"; then
	die "retained evidence does not exactly match RELEASE_EVIDENCE_FILES"
fi

for combination in "${canonical_soaks[@]}"; do
	log="$evidence_dir/soak-$combination.log"
	mapfile -t machine_lines < <(grep '^SOAK_RESULT ' "$log" || true)
	[ "${#machine_lines[@]}" -eq 1 ] \
		|| die "soak-$combination.log must contain exactly one SOAK_RESULT record"
	expected="SOAK_RESULT format=1 status=pass combination=$combination duration_ms=$duration liveness_interval_ms=$liveness checks=$expected_checks failures=0 watchdog_failures=0 liveness_failures=0"
	[ "${machine_lines[0]}" = "$expected" ] \
		|| die "soak-$combination.log has an invalid SOAK_RESULT record"
	mapfile -t pass_lines < <(grep "^SOAK PASS: $duration ms " "$log" || true)
	[ "${#pass_lines[@]}" -eq 1 ] \
		|| die "soak-$combination.log must contain one exact-duration SOAK PASS summary"
	if grep -q '^SOAK FAIL' "$log"; then
		die "soak-$combination.log also contains a SOAK FAIL summary"
	fi
done

grep -Fxq "# Firmware release $expected_version" "$manifest" \
	|| die "MANIFEST.md version does not match QUALIFICATION"
grep -Fxq -- "- **Release mode:** ${q[release_mode]}" "$manifest" \
	|| die "MANIFEST.md release mode does not match QUALIFICATION"
grep -Fxq -- "- **Source commit:** \`${q[source_commit]}\`" "$manifest" \
	|| die "MANIFEST.md source commit does not match QUALIFICATION"
grep -Fxq -- "- **Soak duration per combination:** $duration ms" "$manifest" \
	|| die "MANIFEST.md soak duration does not match QUALIFICATION"
grep -Fxq -- "- **Soak combinations:** ${q[soak_combination_count]}" "$manifest" \
	|| die "MANIFEST.md soak count does not match QUALIFICATION"
if [ "${q[release_mode]}" = production ]; then
	if grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$manifest"; then
		die "production MANIFEST.md contains the dry-run banner"
	fi
else
	grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$manifest" \
		|| die "dry-run MANIFEST.md is missing its warning banner"
fi

printf 'QUALIFIED: %s records clean %s qualification with %d exact %s-ms soak results.\n' \
	"$expected_version" "${q[release_mode]}" "${#canonical_soaks[@]}" "$duration"
