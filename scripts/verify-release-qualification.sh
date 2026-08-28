#!/usr/bin/env bash
# Verify the retained local release qualification before tag CI publishes it.
# This does not rerun the 24-hour soak. It fails unless the committed evidence
# has the exact canonical inventory, PIC12F675's aggregate evidence names one
# retained matrix matching the released bytes, and every soak log carries one
# complete machine-readable result matching the qualification metadata.
set -euo pipefail
LC_ALL=C
export LC_ALL

MIN_RELEASE_SOAK_MS=86400000
# An express release is publishable with a shorter soak, and this floor is the
# only thing that keeps "shorter" from meaning "any". It mirrors
# MIN_EXPRESS_SOAK_MS in scripts/make-release.sh; the producer and this verifier
# must agree, or a run that the producer accepted would be unpublishable.
MIN_EXPRESS_SOAK_MS=3600000
MAX_SOAK_DURATION_MS=4294967294
EXPRESS_BANNER='EXPRESS QUALIFICATION -- SHORTENED SOAK'
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
[[ "$expected_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "invalid expected release version: $expected_version"
git check-ref-format "refs/tags/$expected_version" >/dev/null 2>&1 \
	|| die "invalid expected release version: $expected_version"
[ -d "$release_dir" ] || die "release directory not found: $release_dir"
release_dir=$(cd "$release_dir" && pwd -P) \
	|| die "cannot resolve release directory: $release_dir"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) \
	|| die "cannot locate repository root"
command -v make >/dev/null 2>&1 \
	|| die "make is required to read the canonical release qualification set"
command -v python3 >/dev/null 2>&1 \
	|| die "python3 is required to verify retained PIC12F675 matrix evidence"

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
	soak_duration_ms soak_liveness_interval_ms soak_combination_count \
	pic12f675_matrix_sha256 resource_tables_sha256)
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

[ "${q[format]}" = 3 ] || die "unsupported QUALIFICATION format: ${q[format]}"
[ "${q[version]}" = "$expected_version" ] \
	|| die "QUALIFICATION version ${q[version]} does not match $expected_version"
[[ "${q[source_commit]}" =~ ^[0-9a-f]{40}$ ]] \
	|| die "QUALIFICATION source_commit is not a full lowercase SHA-1"
[[ "${q[pic12f675_matrix_sha256]}" =~ ^[0-9a-f]{64}$ ]] \
	|| die "QUALIFICATION pic12f675_matrix_sha256 is not a lowercase SHA-256"
[[ "${q[resource_tables_sha256]}" =~ ^[0-9a-f]{64}$ ]] \
	|| die "QUALIFICATION resource_tables_sha256 is not a lowercase SHA-256"

case "${q[release_mode]}" in
	production)
		[ "${q[source_dirty]}" = 0 ] \
			|| die "production qualification must record source_dirty=0"
		;;
	express)
		# Publishable, so it is held to every production rule except the soak
		# floor checked below -- and it must SAY so where a reader looks.
		[ "${q[source_dirty]}" = 0 ] \
			|| die "express qualification must record source_dirty=0"
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
if [ "${q[release_mode]}" = express ] \
		&& { [ "${#duration}" -lt "${#MIN_EXPRESS_SOAK_MS}" ] \
			|| { [ "${#duration}" -eq "${#MIN_EXPRESS_SOAK_MS}" ] \
				&& [[ "$duration" < "$MIN_EXPRESS_SOAK_MS" ]]; }; }; then
	die "express soak_duration_ms is below $MIN_EXPRESS_SOAK_MS"
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

# --no-print-directory is required here, and -s does not imply it: Make enables
# -w in a sub-make and propagates a literal w through MAKEFLAGS, where it
# OVERRIDES -s. This verifier runs both standalone (clean MAKEFLAGS) and from
# the test-release-qualification gate, which `make release` reaches through a
# sub-make -- there the directory banner became the first canonical soak name
# and this script rejected a VALID qualification for a count mismatch.
#
# CC=: is a silent placeholder for the AVR compiler. The Makefile discovers
# avr-libc header paths at PARSE time via unconditional `$(shell $(CC)
# -print-file-name ...)`/`-dM` probes (for the static analyzers); on a host
# without avr-gcc those probes print "avr-gcc: command not found" to stderr on
# EVERY make invocation, including this metadata-only query. That noise would
# reach a documented tool-independent path and could mask a real warning or
# trip automation that treats stderr as failure. RELEASE_SOAK_NAMES and
# RELEASE_EVIDENCE_FILES are `override :=` literal inventories with no compiler
# dependence, so `:` (the shell null utility) satisfies the probes silently
# without changing the result. It cannot weaken the canonical set: `override`
# ignores command-line assignments, and CC is not an inventory variable. This
# must be a command-line assignment -- the Makefile's `CC = avr-gcc` overrides
# the environment, so only `make CC=:` takes effect.
canonical_soaks_raw=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-RELEASE_SOAK_NAMES) \
	|| die "cannot read RELEASE_SOAK_NAMES from the Makefile"
canonical_evidence_raw=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-RELEASE_EVIDENCE_FILES) \
	|| die "cannot read RELEASE_EVIDENCE_FILES from the Makefile"
matrix_tool_raw=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-PIC12F675_MATRIX_EVIDENCE) \
	|| die "cannot read PIC12F675_MATRIX_EVIDENCE from the Makefile"
fw_base=$(make -s --no-print-directory CC=: -C "$repo_root" print-FW_BASE) \
	|| die "cannot read FW_BASE from the Makefile"
pic12f675_tag=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-PIC12F675_TAG) \
	|| die "cannot read PIC12F675_TAG from the Makefile"
pic12f675_variants_raw=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-CLASSIC_VARIANTS_SUPPORTED) \
	|| die "cannot read CLASSIC_VARIANTS_SUPPORTED from the Makefile"
case "$matrix_tool_raw" in
	/*) matrix_tool=$matrix_tool_raw ;;
	*) matrix_tool="$repo_root/$matrix_tool_raw" ;;
esac
[ -f "$matrix_tool" ] && [ ! -L "$matrix_tool" ] && [ -s "$matrix_tool" ] \
	|| die "PIC12F675 matrix evidence verifier is missing, empty, or not regular"
read -r -a canonical_soaks <<<"$canonical_soaks_raw"
read -r -a canonical_evidence <<<"$canonical_evidence_raw"
read -r -a pic12f675_variants <<<"$pic12f675_variants_raw"
[ "${#canonical_soaks[@]}" -gt 0 ] || die "canonical release soak set is empty"
[ "${#canonical_evidence[@]}" -gt 0 ] || die "canonical release evidence set is empty"
[ "${#pic12f675_variants[@]}" -eq 3 ] \
	|| die "canonical PIC12F675 variant set does not contain exactly three entries"
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
validate_canonical_names "canonical PIC12F675 variant set" "${pic12f675_variants[@]}"

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

matrix_manifest="$evidence_dir/pic12f675-qualified-matrix.json"
matrix_log="$evidence_dir/pic12f675-qualification.log"
matrix_record=$(python3 "$matrix_tool" verify-release \
	--manifest "$matrix_manifest" --qualification-log "$matrix_log" \
	--release-dir "$release_dir" --fw-base "$fw_base" \
	--tag "$pic12f675_tag" \
	--expected-manifest-sha256 "${q[pic12f675_matrix_sha256]}") \
	|| die "retained PIC12F675 matrix does not match the released images and checksums"
[[ "$matrix_record" == "PIC12F675_MATRIX_SHA256 format=2 "* ]] \
	|| die "retained PIC12F675 matrix verifier returned an invalid identity record"

resource_log="$evidence_dir/resource-tables.log"
resource_digest=$(sha256sum -- "$resource_log") \
	|| die "could not hash retained resource evidence"
resource_digest=${resource_digest%% *}
[ "$resource_digest" = "${q[resource_tables_sha256]}" ] \
	|| die "retained resource evidence digest does not match QUALIFICATION"
resource_result="RESOURCE_TABLES_RESULT format=1 status=pass source_commit=${q[source_commit]} images=21 avr_static=12 classic_stack=9 pic_data=6 pic_stack=9"
mapfile -t resource_results < <(grep '^RESOURCE_TABLES_RESULT ' "$resource_log" || true)
[ "${#resource_results[@]}" -eq 1 ] && [ "${resource_results[0]}" = "$resource_result" ] \
	|| die "retained resource evidence has no exact source-bound complete result"

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
grep -Fxq -- "- **PIC12F675 qualified matrix:** \`evidence/pic12f675-qualified-matrix.json\` (SHA-256 \`${q[pic12f675_matrix_sha256]}\`)" "$manifest" \
	|| die "MANIFEST.md PIC12F675 matrix digest does not match QUALIFICATION"
grep -Fxq -- "- **Final resource evidence:** \`evidence/resource-tables.log\` (SHA-256 \`${q[resource_tables_sha256]}\`)" "$manifest" \
	|| die "MANIFEST.md resource evidence digest does not match QUALIFICATION"
# Each mode carries exactly its own banner, checked in both directions. The
# recorded mode and the human-readable document are the same claim written
# twice, and a reader who sees only one of them must not be misled by it: a
# production manifest that quietly carries a shortened-soak banner, or an
# express manifest that carries none, is a mismatch either way.
case "${q[release_mode]}" in
	production)
		if grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$manifest"; then
			die "production MANIFEST.md contains the dry-run banner"
		fi
		if grep -Fq "$EXPRESS_BANNER" "$manifest"; then
			die "production MANIFEST.md contains the express banner"
		fi
		;;
	express)
		if grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$manifest"; then
			die "express MANIFEST.md contains the dry-run banner"
		fi
		grep -Fq "$EXPRESS_BANNER" "$manifest" \
			|| die "express MANIFEST.md is missing its shortened-soak banner"
		;;
	*)
		grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$manifest" \
			|| die "dry-run MANIFEST.md is missing its warning banner"
		;;
esac

printf 'QUALIFIED: %s records clean %s qualification with %d exact %s-ms soak results.\n' \
	"$expected_version" "${q[release_mode]}" "${#canonical_soaks[@]}" "$duration"
