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
readme="$release_dir/README.md"
checksums="$release_dir/SHA256SUMS"
evidence_dir="$release_dir/evidence"
[ -f "$qualification" ] && [ ! -L "$qualification" ] && [ -s "$qualification" ] \
	|| die "QUALIFICATION is missing, empty, or not a regular file"
[ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -s "$manifest" ] \
	|| die "MANIFEST.md is missing, empty, or not a regular file"
[ -f "$readme" ] && [ ! -L "$readme" ] && [ -s "$readme" ] \
	|| die "README.md is missing, empty, or not a regular file"
[ -f "$checksums" ] && [ ! -L "$checksums" ] && [ -s "$checksums" ] \
	|| die "SHA256SUMS is missing, empty, or not a regular file"
[ -d "$evidence_dir" ] && [ ! -L "$evidence_dir" ] \
	|| die "evidence is missing or not a real directory"

# Strict key=value schema. Never source release metadata: it is committed input
# to a privileged workflow and must remain data, not shell code.
declare -A q=()
required_keys=(format version release_mode source_commit source_dirty \
	soak_duration_ms soak_liveness_interval_ms soak_combination_count \
	pic12f675_matrix_sha256 resource_tables_sha256 toolchain_sha256 \
	evidence_index_sha256)
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

# format=4 brought the provenance files inside SHA256SUMS, so one signature
# verification reaches where the firmware came from. format=5 adds
# toolchain_sha256: the MANIFEST toolchain table stopped being authored prose
# and is now rendered from bound evidence. format=6 added evidence_index_sha256
# and length-attributed the thirteen retained build and target-test logs. Format
# 7 closes the remaining same-shape substitution gap: each operation seals its
# exact transcript payload by SHA-256 before appending its terminal result, which
# the index commits through the existing qualification root. Releases through
# v0.9.11 declare format=3 or format=1 or nothing at all and signed the firmware
# only.
#
# Exactly one format is accepted here. This verifier runs on a freshly staged
# directory and on the tag CI is publishing, never on a historical release, so
# a compatibility branch would be unreachable code claiming a capability
# nothing exercises. verify-release-images.sh, which IS run against published
# directories, carries the era policy instead.
[ "${q[format]}" = 7 ] || die "unsupported QUALIFICATION format: ${q[format]}"
[ "${q[version]}" = "$expected_version" ] \
	|| die "QUALIFICATION version ${q[version]} does not match $expected_version"
[[ "${q[source_commit]}" =~ ^[0-9a-f]{40}$ ]] \
	|| die "QUALIFICATION source_commit is not a full lowercase SHA-1"
[[ "${q[pic12f675_matrix_sha256]}" =~ ^[0-9a-f]{64}$ ]] \
	|| die "QUALIFICATION pic12f675_matrix_sha256 is not a lowercase SHA-256"
[[ "${q[resource_tables_sha256]}" =~ ^[0-9a-f]{64}$ ]] \
	|| die "QUALIFICATION resource_tables_sha256 is not a lowercase SHA-256"
[[ "${q[evidence_index_sha256]}" =~ ^[0-9a-f]{64}$ ]] \
	|| die "QUALIFICATION evidence_index_sha256 is not a lowercase SHA-256"
[[ "${q[toolchain_sha256]}" =~ ^[0-9a-f]{64}$ ]] \
	|| die "QUALIFICATION toolchain_sha256 is not a lowercase SHA-256"

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
canonical_roles_raw=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-RELEASE_EVIDENCE_ROLES) \
	|| die "cannot read RELEASE_EVIDENCE_ROLES from the Makefile"
result_roles_raw=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-RELEASE_EVIDENCE_RESULT_ROLES) \
	|| die "cannot read RELEASE_EVIDENCE_RESULT_ROLES from the Makefile"
canonical_images=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-RELEASE_IMAGES) \
	|| die "cannot read RELEASE_IMAGES from the Makefile"
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
read -r -a canonical_roles <<<"$canonical_roles_raw"
read -r -a result_roles <<<"$result_roles_raw"
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
validate_canonical_names "evidence result role set" "${result_roles[@]}"
[ "$(printf '%s\n' "${result_roles[@]}" | sort)" = $'build\ntarget-test' ] \
	|| die "RELEASE_EVIDENCE_RESULT_ROLES must be exactly build and target-test"

# The declared role of every retained file. Read from the Makefile rather than
# from the index being checked: an index that supplied its own role vocabulary
# would agree with itself about a mislabelled member. The map must be the
# evidence set with INDEX removed -- exactly, both directions -- so a retained
# file that nobody classified cannot slip out of the index unremarked.
declare -A evidence_role=()
for role_entry in "${canonical_roles[@]}"; do
	role_base=${role_entry%%=*}
	role_name=${role_entry#*=}
	[ -n "$role_base" ] && [ -n "$role_name" ] && [ "$role_base" != "$role_entry" ] \
		|| die "malformed RELEASE_EVIDENCE_ROLES entry: $role_entry"
	[[ "$role_name" =~ ^[a-z][a-z-]*$ ]] || die "invalid evidence role: $role_name"
	[ "${evidence_role[$role_base]+set}" != set ] \
		|| die "duplicate evidence name in the role map: $role_base"
	evidence_role[$role_base]=$role_name
done
[ "${evidence_role[INDEX]+set}" != set ] \
	|| die "the evidence role map must not describe INDEX, which cannot describe itself"
indexed_names=()
for name in "${canonical_evidence[@]}"; do
	[ "$name" = INDEX ] && continue
	[ "${evidence_role[$name]+set}" = set ] \
		|| die "retained evidence file has no declared role: $name"
	indexed_names+=("$name")
done
[ "${#indexed_names[@]}" -eq "${#evidence_role[@]}" ] \
	|| die "the evidence role map does not cover exactly the retained evidence set"
[ "${#indexed_names[@]}" -lt "${#canonical_evidence[@]}" ] \
	|| die "RELEASE_EVIDENCE_FILES does not retain INDEX"
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
# The terminal result is checked further down, with the records it summarizes:
# its records= count has to equal the number of figures actually present, and
# that number is not known until they have been parsed.

# test-long's complete transcript is transient diagnostic output, not release
# evidence. Its retained summary must still establish the exact aggregate,
# strict-tool/mutation policy, source identity, and successful terminal result.
test_long_summary="$evidence_dir/test-long.summary.txt"
test_long_result="TEST_LONG_RESULT format=1 status=pass source_commit=${q[source_commit]} target=test-long strict_tools=1 mutation_allow_skip=0"
mapfile -t test_long_results < <(grep '^TEST_LONG_RESULT ' "$test_long_summary" || true)
[ "${#test_long_results[@]}" -eq 1 ] \
	|| die "test-long.summary.txt must contain exactly one TEST_LONG_RESULT record"
[ "${test_long_results[0]}" = "$test_long_result" ] \
	|| die "test-long.summary.txt has no exact source-bound passing test-long result"

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

# --- the toolchain table is rendered from evidence, and still matches it ------
# Fifteen rows of compiler, simulator and analyzer versions were authored output
# until format=5: printed into MANIFEST.md from shell captures, with no machine
# authority and nothing checking them, so a wrong version there was a provenance
# error that passed every gate. Now they are recorded once and rendered from the
# record. Both directions are checked, because either alone is satisfiable by a
# table that is wrong: every record must appear as a row, and every row must
# come from a record.
# Existence, regularity and non-emptiness are already established by the
# canonical evidence-set comparison above, which is why resource-tables.log
# below is opened the same way -- without a second guard that could never fire.
toolchain_log="$evidence_dir/toolchain.txt"
toolchain_digest=$(sha256sum -- "$toolchain_log") \
	|| die "could not hash retained toolchain evidence"
[ "${toolchain_digest%% *}" = "${q[toolchain_sha256]}" ] \
	|| die "retained toolchain evidence digest does not match QUALIFICATION"

toolchain_result="TOOLCHAIN_RESULT format=1 status=pass rows=15 source_commit=${q[source_commit]}"
mapfile -t toolchain_results < <(grep '^TOOLCHAIN_RESULT ' "$toolchain_log" || true)
[ "${#toolchain_results[@]}" -eq 1 ] && [ "${toolchain_results[0]}" = "$toolchain_result" ] \
	|| die "toolchain evidence has no exact source-bound complete result"
grep -Fxq "TOOLCHAIN format=1 source_commit=${q[source_commit]}" "$toolchain_log" \
	|| die "toolchain evidence has no source-bound header record"

toolchain_rows=0
while IFS=$'\t' read -r tool_label tool_version; do
	case "$tool_label" in
		TOOLCHAIN\ *|TOOLCHAIN_RESULT\ *) continue ;;
	esac
	[ -n "$tool_label" ] && [ -n "$tool_version" ] \
		|| die "malformed toolchain evidence record: $tool_label"
	grep -Fxq -- "| $tool_label | $tool_version |" "$manifest" \
		|| die "MANIFEST.md toolchain table omits the recorded row for $tool_label"
	toolchain_rows=$((toolchain_rows + 1))
done < "$toolchain_log"
[ "$toolchain_rows" -eq 15 ] \
	|| die "toolchain evidence records $toolchain_rows tools, expected 15"

# The other direction. Counting the table's own rows is what catches a row the
# record does not justify -- an extra tool, or a version edited in place after
# the table was rendered.
rendered_rows=$(sed -n '/^## Toolchain$/,/^## /p' "$manifest" \
	| grep -c '^| .* | .* |$') \
	|| die "could not read the MANIFEST.md toolchain table"
# The header row `| tool | version |` matches that shape too.
[ "$rendered_rows" -eq $((toolchain_rows + 1)) ] \
	|| die "MANIFEST.md toolchain table has $rendered_rows rows for $toolchain_rows recorded tools"

# --- the evidence index, and the thirteen logs it made checkable --------------
# Until format=6 the qualification verifier established, for every build log and
# every target-test log, only that a file of that name existed and was not empty.
# Format 6 added source/name/role/length attribution but still accepted a payload
# substitution preserving size and line count. Format 7 rehashes the exact bytes
# preceding each operation-sealed result, independently of the producer.
#
# The index is checked against the Makefile's declared role map and against the
# files themselves, never against its own claims. Three ways to get this wrong
# are all closed: a row whose role disagrees with the declaration, a row whose
# size or record disagrees with the file, and a member with no row at all.
index_log="$evidence_dir/INDEX"
index_digest=$(sha256sum -- "$index_log") \
	|| die "could not hash the retained evidence index"
[ "${index_digest%% *}" = "${q[evidence_index_sha256]}" ] \
	|| die "retained evidence index digest does not match QUALIFICATION"

grep -Fxq "EVIDENCE_INDEX format=2 source_commit=${q[source_commit]}" "$index_log" \
	|| die "evidence index has no source-bound header record"
index_result="EVIDENCE_INDEX_RESULT format=2 status=pass members=${#indexed_names[@]} source_commit=${q[source_commit]}"
mapfile -t index_results < <(grep '^EVIDENCE_INDEX_RESULT ' "$index_log" || true)
[ "${#index_results[@]}" -eq 1 ] && [ "${index_results[0]}" = "$index_result" ] \
	|| die "evidence index has no exact source-bound complete result"

# The expected terminal record for one member, derived the same way the release
# derived it. The default arm is a hard failure, not a `-`: a role added to the
# Makefile with no rule here must stop the release rather than be reported as
# having concluded nothing.
expected_terminal_record() {
	local role=$1 path=$2 name=$3 pattern matches total_lines payload_lines digest
	case "$role" in
		build|target-test)
			[ -z "$(tail -c 1 "$path")" ] || return 1
			total_lines=$(wc -l < "$path") || return 1
			[ "$total_lines" -ge 2 ] || return 1
			payload_lines=$((total_lines - 1))
			digest=$(head -n "$payload_lines" "$path" | sha256sum) || return 1
			digest=${digest%% *}
			printf 'EVIDENCE_RESULT format=2 status=pass role=%s evidence=%s lines=%d payload_sha256=%s source_commit=%s\n' \
				"$role" "$name" "$payload_lines" "$digest" "${q[source_commit]}"
			return 0 ;;
		soak)                 pattern='^SOAK_RESULT ' ;;
		test-long)            pattern='^TEST_LONG_RESULT ' ;;
		resource)             pattern='^RESOURCE_TABLES_RESULT ' ;;
		toolchain)            pattern='^TOOLCHAIN_RESULT ' ;;
		qualification|matrix) printf '%s\n' '-'; return 0 ;;
		*) return 1 ;;
	esac
	mapfile -t matches < <(grep "$pattern" "$path" || true)
	[ "${#matches[@]}" -eq 1 ] || return 1
	printf '%s\n' "${matches[0]}"
}

declare -A index_seen=()
index_rows=0
while IFS=$'\t' read -r index_name index_role index_size index_record; do
	case "$index_name" in
		EVIDENCE_INDEX\ *|EVIDENCE_INDEX_RESULT\ *) continue ;;
	esac
	[ -n "$index_name" ] && [ -n "$index_role" ] && [ -n "$index_size" ] \
		&& [ -n "$index_record" ] \
		|| die "malformed evidence index row: $index_name"
	[ "${index_seen[$index_name]+set}" != set ] \
		|| die "evidence index lists $index_name twice"
	index_seen[$index_name]=1
	[ "${evidence_role[$index_name]+set}" = set ] \
		|| die "evidence index lists $index_name, which is not retained evidence"
	[ "$index_role" = "${evidence_role[$index_name]}" ] \
		|| die "evidence index calls $index_name a $index_role; the Makefile declares ${evidence_role[$index_name]}"
	member="$evidence_dir/$index_name"
	member_size=$(stat -c%s "$member") \
		|| die "could not size retained evidence: $index_name"
	[ "$index_size" = "$member_size" ] \
		|| die "evidence index records $index_name as $index_size bytes; it is $member_size"
	# For the thirteen, validate the member before the index row. A same-size,
	# same-line-count payload substitution leaves member and index agreeing with
	# each other about the OLD digest; independent rehashing must be what fails.
	case "$index_role" in
		build|target-test)
			mapfile -t member_results < <(grep '^EVIDENCE_RESULT ' "$member" || true)
			[ "${#member_results[@]}" -eq 1 ] \
				|| die "$index_name carries ${#member_results[@]} EVIDENCE_RESULT records, expected 1"
			[ "$(tail -n 1 "$member")" = "${member_results[0]}" ] \
				|| die "$index_name EVIDENCE_RESULT is not the final line"
			;;
	esac
	expected_record=$(expected_terminal_record "$index_role" "$member" "$index_name") \
		|| die "no single terminal record for $index_name (role $index_role)"
	case "$index_role" in
		build|target-test)
			[ "${member_results[0]}" = "$expected_record" ] \
				|| die "$index_name payload digest or result metadata does not match its transcript"
			;;
	esac
	[ "$index_record" = "$expected_record" ] \
		|| die "evidence index misreports the terminal record of $index_name"
	index_rows=$((index_rows + 1))
done < "$index_log"
[ "$index_rows" -eq "${#indexed_names[@]}" ] \
	|| die "evidence index lists $index_rows members, expected ${#indexed_names[@]}"
for name in "${indexed_names[@]}"; do
	[ "${index_seen[$name]+set}" = set ] \
		|| die "evidence index omits retained evidence: $name"
done

grep -Fxq -- "- **Evidence index:** \`evidence/INDEX\` (SHA-256 \`${q[evidence_index_sha256]}\`), ${#indexed_names[@]} retained files by role and terminal record" "$manifest" \
	|| die "MANIFEST.md evidence index digest does not match QUALIFICATION"

# --- the measured resource figures, and the manifest rows they produced -------
# Until now the release published a flash column the producer derived for itself,
# arm by arm, from build logs and avr-size -- and derived nothing at all for the
# PIC10F322, printing "n/a" for the three tightest images in the release. The
# gate that measured the same artifacts against the reviewed ceilings kept only
# counts. Neither figure was ever compared with the other, because only one of
# them existed at a time.
#
# Both now come from the RESOURCE_* records in evidence/resource-tables.log,
# which SHA256SUMS signs, evidence/INDEX records and QUALIFICATION binds by
# digest. This block re-derives every published row from those records and
# requires the manifest to carry it exactly. The derivations below are a
# deliberate second implementation of the producer's, not a shared one: this
# verifier links nothing from the release script on purpose, so a renderer that
# drifts from the record it renders is caught by disagreement rather than
# reproduced identically on both sides.
# $resource_log was set and its digest checked against QUALIFICATION above.

resource_unit_label() {
	case "$1" in
		bytes)  printf 'B\n' ;;
		words)  printf 'words\n' ;;
		levels) printf 'levels\n' ;;
		*) return 1 ;;
	esac
}

resource_decimal() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
}

# The decimal fields each record kind must carry. A record missing one is a
# truncated record, not a record with a default, so the field list is declared
# rather than discovered from whatever the record happens to contain.
declare -A resource_required=(
	[RESOURCE_IMAGE]="used ceiling capacity free"
	[RESOURCE_STATIC]="static ceiling free images"
	[RESOURCE_STACK]="used free static sram floor observations"
	[RESOURCE_STACK_BOUND]="reports ceiling"
	[RESOURCE_DATA]="used ceiling capacity free"
	[RESOURCE_RETURN_STACK]="peak reserve spare depth"
)
declare -A resource_cell=()
declare -A resource_seen=()
resource_rows=()
resource_summaries=0
while IFS= read -r resource_line; do
	resource_kind=${resource_line%% *}
	case "$resource_kind" in
		RESOURCE_TABLES_RESULT)
			resource_summaries=$((resource_summaries + 1)); continue ;;
	esac
	declare -A rf=()
	for resource_pair in $resource_line; do
		case "$resource_pair" in
			*=*) rf[${resource_pair%%=*}]=${resource_pair#*=} ;;
		esac
	done
	[ "${rf[format]:-}" = 1 ] \
		|| die "a $resource_kind record in the resource evidence is not format=1"
	resource_label=$(resource_unit_label "${rf[unit]:-}") \
		|| die "a $resource_kind record names no known unit"
	[ "${resource_required[$resource_kind]+set}" = set ] \
		|| die "unknown resource record in the resource evidence: $resource_kind"
	for resource_key in ${resource_required[$resource_kind]}; do
		resource_decimal "${rf[$resource_key]:-}" \
			|| die "a $resource_kind record has no decimal $resource_key field"
	done
	case "$resource_kind" in
	RESOURCE_IMAGE)
		[ -n "${rf[image]:-}" ] || die "a RESOURCE_IMAGE record names no image"
		[ "${resource_seen[${rf[image]}]+set}" != set ] \
			|| die "two RESOURCE_IMAGE records for ${rf[image]}"
		resource_seen[${rf[image]}]=1
		[ "${rf[free]}" -eq $(( rf[ceiling] - rf[used] )) ] \
			|| die "${rf[image]} reports a free margin that is not its ceiling less its use"
		[ "${rf[used]}" -gt 0 ] && [ "${rf[used]}" -le "${rf[ceiling]}" ] \
			&& [ "${rf[ceiling]}" -le "${rf[capacity]}" ] \
			|| die "${rf[image]} does not order use, ceiling and capacity"
		resource_cell[${rf[image]}]=$(printf '%s / %s %s (%s free)' \
			"${rf[used]}" "${rf[ceiling]}" "$resource_label" "${rf[free]}") ;;
	RESOURCE_STATIC)
		[ "${rf[free]}" -eq $(( rf[ceiling] - rf[static] )) ] \
			|| die "the ${rf[part]:-?} static record's free margin does not close"
		[ "${rf[static]}" -gt 0 ] && [ "${rf[images]}" -gt 0 ] \
			|| die "the ${rf[part]:-?} static record measures nothing"
		resource_rows+=("$(printf '| `%s` | %s %s | %s %s | %s %s | %s |' \
			"${rf[part]:-}" "${rf[static]}" "$resource_label" \
			"${rf[ceiling]}" "$resource_label" "${rf[free]}" "$resource_label" \
			"${rf[images]}")") ;;
	RESOURCE_STACK)
		[ $(( rf[static] + rf[used] + rf[free] )) -eq "${rf[sram]}" ] \
			|| die "the ${rf[part]:-?} stack record does not account for the whole device SRAM"
		[ "${rf[free]}" -ge "${rf[floor]}" ] \
			|| die "the ${rf[part]:-?} stack record is below the canary gate's own floor"
		[ "${rf[observations]}" -gt 0 ] \
			|| die "the ${rf[part]:-?} stack record summarizes no observation"
		resource_rows+=("$(printf '| `%s` | %s | %s %s | %s %s | %s %s | %s %s | %s %s | %s |' \
			"${rf[part]:-}" "${rf[deepest_sp]:-}" "${rf[used]}" "$resource_label" \
			"${rf[free]}" "$resource_label" "${rf[static]}" "$resource_label" \
			"${rf[sram]}" "$resource_label" "${rf[floor]}" "$resource_label" \
			"${rf[observations]}")") ;;
	RESOURCE_STACK_BOUND)
		[ "${rf[reports]}" -gt 0 ] \
			|| die "the ${rf[part]:-?} frame-bound record cites no report"
		# A per-frame compiler bound is not a high-water measurement, and this
		# row must not read as one: the record carries no use or peak, and the
		# rendered row states only the ceiling every frame was checked against.
		[ "${rf[used]+set}" != set ] && [ "${rf[peak]+set}" != set ] \
			|| die "the ${rf[part]:-?} frame-bound record claims a high-water figure the evidence does not contain"
		resource_rows+=("$(printf '| `%s` | %s | %s | every frame <= %s %s |' \
			"${rf[part]:-}" "${rf[method]:-}" "${rf[reports]}" \
			"${rf[ceiling]}" "$resource_label")") ;;
	RESOURCE_DATA)
		[ -n "${rf[variant]:-}" ] || die "a RESOURCE_DATA record names no variant"
		[ "${rf[free]}" -eq $(( rf[ceiling] - rf[used] )) ] \
			|| die "the ${rf[part]:-?} ${rf[variant]} data record's free margin does not close"
		[ "${rf[used]}" -gt 0 ] && [ "${rf[used]}" -le "${rf[ceiling]}" ] \
			&& [ "${rf[ceiling]}" -le "${rf[capacity]}" ] \
			|| die "the ${rf[part]:-?} ${rf[variant]} data record does not order use, ceiling and capacity"
		resource_rows+=("$(printf '| `%s` | %s | %s %s | %s %s | %s %s | %s %s |' \
			"${rf[part]:-}" "${rf[variant]}" "${rf[used]}" "$resource_label" \
			"${rf[ceiling]}" "$resource_label" "${rf[capacity]}" "$resource_label" \
			"${rf[free]}" "$resource_label")") ;;
	RESOURCE_RETURN_STACK)
		[ -n "${rf[variant]:-}" ] \
			|| die "a RESOURCE_RETURN_STACK record names no variant"
		[ $(( rf[peak] + rf[reserve] + rf[spare] )) -eq "${rf[depth]}" ] \
			|| die "the ${rf[part]:-?} ${rf[variant]} return-stack record does not account for the whole hardware stack"
		[ "${rf[peak]}" -gt 0 ] \
			|| die "the ${rf[part]:-?} ${rf[variant]} return-stack record measures no call depth"
		resource_rows+=("$(printf '| `%s` | %s | %s | %s | %s | %s |' \
			"${rf[part]:-}" "${rf[variant]}" "${rf[peak]}" "${rf[reserve]}" \
			"${rf[spare]}" "${rf[depth]}")") ;;
	# Reached only if a kind gains a required-field list above without gaining
	# a row here, which would otherwise render nothing and check nothing.
	*) die "resource record $resource_kind has no rendered row" ;;
	esac
done < <(grep '^RESOURCE_[A-Z_]* ' "$resource_log" || true)
[ "$resource_summaries" -eq 1 ] \
	|| die "the resource evidence carries $resource_summaries terminal result records, expected 1"

# Coverage in both directions against the canonical image set, not against a
# remembered count: an image with no measurement is as wrong as a measurement
# for an image this release does not ship.
for resource_image in $canonical_images; do
	[ "${resource_cell[$resource_image]+set}" = set ] \
		|| die "no measured resource record for the release image $resource_image"
done
for resource_image in "${!resource_cell[@]}"; do
	case " $canonical_images " in
		*" $resource_image "*) ;;
		*) die "a resource record measures $resource_image, which this release does not ship" ;;
	esac
done

# The terminal record's own count must equal the figures actually present. A
# truncated log loses records; one that lost records must not still claim to
# summarize them.
resource_result="RESOURCE_TABLES_RESULT format=1 status=pass source_commit=${q[source_commit]} images=21 avr_static=12 classic_stack=9 pic_data=6 pic_stack=9 records=$(( ${#resource_cell[@]} + ${#resource_rows[@]} ))"
mapfile -t resource_results < <(grep '^RESOURCE_TABLES_RESULT ' "$resource_log" || true)
[ "${resource_results[0]}" = "$resource_result" ] \
	|| die "retained resource evidence has no exact source-bound complete result"

# The column order is pinned before any cell is read from it: this block picks
# the flash figure out of the row by position, so a producer that reordered the
# columns would otherwise have it comparing the clock against a measurement.
grep -Fxq -- '| image | MCU | clock | flash used / reviewed ceiling | fuses / config | sha256 |' "$manifest" \
	|| die "MANIFEST.md does not carry the expected image table header"
grep -Fxq -- '## Resources' "$manifest" \
	|| die "MANIFEST.md does not carry the measured resources section"

# The manifest's flash column, cell by cell. The rest of the row -- MCU, clock,
# fuses, digest -- is bound elsewhere; what is checked here is that the figure
# the reader sees is the figure the gate passed on.
for resource_image in $canonical_images; do
	mapfile -t resource_matches < <(grep -F -- "| \`$resource_image\` |" "$manifest" || true)
	[ "${#resource_matches[@]}" -eq 1 ] \
		|| die "MANIFEST.md carries ${#resource_matches[@]} image rows for $resource_image, expected 1"
	IFS='|' read -r -a resource_cells <<<"${resource_matches[0]}"
	[ "${#resource_cells[@]}" -ge 6 ] \
		|| die "MANIFEST.md image row for $resource_image has too few columns"
	resource_shown=${resource_cells[4]}
	resource_shown=${resource_shown#"${resource_shown%%[![:space:]]*}"}
	resource_shown=${resource_shown%"${resource_shown##*[![:space:]]}"}
	[ "$resource_shown" = "${resource_cell[$resource_image]}" ] \
		|| die "MANIFEST.md publishes '$resource_shown' for $resource_image; the measured record says '${resource_cell[$resource_image]}'"
done

for resource_row in "${resource_rows[@]}"; do
	grep -Fxq -- "$resource_row" "$manifest" \
		|| die "MANIFEST.md omits a measured resource row: $resource_row"
done
[ "${#resource_rows[@]}" -gt 0 ] \
	|| die "the resource evidence published no resource rows at all"

# --- the published programming commands --------------------------------------
# Re-derived here from the staged MANIFEST alone, with a second implementation,
# because until now nothing checked this section at all. The one part with a
# guarded transaction had its published procedure pinned in about thirty places;
# the other eighteen images had none, and v0.9.11 published six lines that are
# not valid shell, nine that lose their `-c` option to a shell redirection, and
# two forms that invoke a Makefile no downloaded release contains.
for flash_heading in '## Flashing' '### Programmer profiles' '### Per-image commands'; do
	grep -Fxq -- "$flash_heading" "$manifest" \
		|| die "MANIFEST.md does not carry the $flash_heading section"
done

flash_block="$work/flash-commands.sh"
awk '
	$0 == "### Per-image commands" { want = 1; next }
	want && $0 == "```sh"          { inblock = 1; want = 0; next }
	inblock && $0 == "```"         { exit }
	inblock                        { print }
' "$manifest" > "$flash_block" \
	|| die "could not read the per-image command block from MANIFEST.md"
[ -s "$flash_block" ] \
	|| die "MANIFEST.md publishes an empty per-image command block"

# The reader's interpreter is the authority on whether a line is pasteable.
bash -n "$flash_block" \
	|| die "MANIFEST.md publishes programming commands that are not valid shell"

declare -A flash_command=()
flash_current=""
while IFS= read -r flash_line; do
	case "$flash_line" in
		'') continue ;;
		'# '*)
			[ -z "$flash_current" ] \
				|| die "MANIFEST.md names $flash_current in the command block and publishes no command for it"
			flash_current=${flash_line#\# }
			[ -z "${flash_command[$flash_current]+set}" ] \
				|| die "MANIFEST.md publishes more than one command for $flash_current"
			continue ;;
	esac
	[ -n "$flash_current" ] \
		|| die "MANIFEST.md publishes a programming command that names no image: $flash_line"
	flash_command[$flash_current]=$flash_line
	flash_current=""
done < "$flash_block"
[ -z "$flash_current" ] \
	|| die "MANIFEST.md names $flash_current in the command block and publishes no command for it"

# Coverage, both directions, against the Makefile's canonical set. PIC12F675 is
# the one part that must NOT appear: it is written only through the guarded
# transaction, and a per-image shortcut for it is a defect, not an omission.
for flash_image in $canonical_images; do
	case "$flash_image" in
		*-pic12f675-*.hex)
			[ -z "${flash_command[$flash_image]+set}" ] \
				|| die "MANIFEST.md publishes a raw per-image write for $flash_image" ;;
		*)
			[ -n "${flash_command[$flash_image]+set}" ] \
				|| die "MANIFEST.md publishes no programming command for $flash_image" ;;
	esac
done
for flash_image in "${!flash_command[@]}"; do
	case " $canonical_images " in
		*" $flash_image "*) ;;
		*) die "MANIFEST.md publishes a programming command for $flash_image, which this release does not ship" ;;
	esac
done

for flash_image in "${!flash_command[@]}"; do
	flash_line=${flash_command[$flash_image]}
	case "$flash_line" in
		*"$flash_image"*) ;;
		*) die "the published command for $flash_image does not name that image: $flash_line" ;;
	esac
	case "$flash_line" in
		*'<'*|*'>'*)
			die "the published command for $flash_image carries an unresolved placeholder: $flash_line" ;;
		*'(or:'*)
			die "the published command for $flash_image appends prose to an executable line: $flash_line" ;;
		*'make '*)
			die "the published command for $flash_image invokes make; a downloaded release ships no Makefile" ;;
	esac
	# Whatever wrote the device has to have read it back.
	case "$flash_line" in
		avrdude\ *)
			case " $flash_line " in
				*' -V '*) die "the published avrdude command for $flash_image disables verification" ;;
			esac
			case "$flash_line" in
				*" -U flash:w:$flash_image:i"*) ;;
				*) die "the published avrdude command for $flash_image does not write that image to flash" ;;
			esac ;;
		pk2cmd\ *)
			flash_pk2_command=${flash_line%%#*}
			[[ "$flash_pk2_command" =~ ^pk2cmd([[:space:]]+-[-A-Za-z0-9._/:=]+)+[[:space:]]*$ ]] \
				|| die "the published pk2cmd command for $flash_image is not one plain writer invocation"
			read -r -a flash_pk2_args <<<"$flash_pk2_command"
			flash_pk2_image=""
			flash_pk2_image_count=0
			for flash_pk2_arg in "${flash_pk2_args[@]}"; do
				case "$flash_pk2_arg" in
					-F*)
						flash_pk2_image=${flash_pk2_arg#-F}
						flash_pk2_image_count=$((flash_pk2_image_count + 1)) ;;
				esac
			done
			[ "$flash_pk2_image_count" -eq 1 ] \
				&& [ "$flash_pk2_image" = "$flash_image" ] \
				|| die "the published pk2cmd command for $flash_image does not select $flash_image as its sole -F image operand"
			case " $flash_pk2_command " in
				*' -M '*) ;;
				*) die "the published pk2cmd command for $flash_image does not program the whole device" ;;
			esac
			case " $flash_pk2_command " in
				*' -Y '*) ;;
				*) die "the published pk2cmd command for $flash_image performs no verify pass" ;;
			esac ;;
		*) die "the published command for $flash_image names no programming tool this verifier knows: $flash_line" ;;
	esac

	# The fuse bytes, against the cell the same page shows the reader. Two
	# renderings of one design value, and nothing compared them before.
	mapfile -t flash_matches < <(grep -F -- "| \`$flash_image\` |" "$manifest" || true)
	[ "${#flash_matches[@]}" -eq 1 ] \
		|| die "MANIFEST.md carries ${#flash_matches[@]} image rows for $flash_image, expected 1"
	IFS='|' read -r -a flash_cells <<<"${flash_matches[0]}"
	[ "${#flash_cells[@]}" -ge 7 ] \
		|| die "MANIFEST.md image row for $flash_image has too few columns"
	flash_fuses=${flash_cells[5]}
	for flash_fuse in $flash_fuses; do
		case "$flash_fuse" in
			*=*) ;;
			*) continue ;;
		esac
		case "$flash_line" in
			*" -U ${flash_fuse%%=*}:w:${flash_fuse#*=}:m"*) ;;
			*) die "the published command for $flash_image omits $flash_fuse, which its own Images row publishes" ;;
		esac
	done
done

# The source-checkout block, if the release publishes one, must be exactly what
# it says: make invocations, each selecting the variant its own image names.
if grep -Fxq -- '### Source-checkout equivalents' "$manifest"; then
	flash_source="$work/flash-source.sh"
	awk '
		$0 == "### Source-checkout equivalents" { want = 1; next }
		want && $0 == "```sh"                   { inblock = 1; want = 0; next }
		inblock && $0 == "```"                  { exit }
		inblock                                 { print }
	' "$manifest" > "$flash_source" \
		|| die "could not read the source-checkout block from MANIFEST.md"
	[ -s "$flash_source" ] \
		|| die "MANIFEST.md publishes an empty source-checkout block"
	bash -n "$flash_source" \
		|| die "MANIFEST.md publishes source-checkout commands that are not valid shell"
	flash_current=""
	while IFS= read -r flash_line; do
		case "$flash_line" in
			'') continue ;;
			'# '*) flash_current=${flash_line#\# }; continue ;;
		esac
		[ -n "$flash_current" ] \
			|| die "MANIFEST.md publishes a source-checkout command that names no image: $flash_line"
		case " $canonical_images " in
			*" $flash_current "*) ;;
			*) die "MANIFEST.md publishes a source-checkout command for $flash_current, which this release does not ship" ;;
		esac
		case "$flash_line" in
			'make '*) ;;
			*) die "the source-checkout command for $flash_current is not a make invocation: $flash_line" ;;
		esac
		flash_stem=${flash_current%.hex}
		case "$flash_line" in
			*"VARIANT=${flash_stem##*-}"*) ;;
			*) die "the source-checkout command for $flash_current does not select its own variant: $flash_line" ;;
		esac
		flash_current=""
	done < "$flash_source"
fi

# --- the provenance files are inside the signature ---------------------------
# verify-release-images.sh proves SHA256SUMS LISTS exactly the declared
# provenance set. That is a different claim from the listed digests being the
# digests of the files actually sitting here: a release could name
# QUALIFICATION in its checksum list and ship a QUALIFICATION that does not
# hash to the listed value, and `sha256sum -c` would fail only for whoever
# thought to run it. Recompute here, at the point the release is qualified.
provenance_raw=$(make -s --no-print-directory CC=: -C "$repo_root" \
	print-RELEASE_PROVENANCE_FILES) \
	|| die "could not read RELEASE_PROVENANCE_FILES from the Makefile"
read -r -a provenance_list <<<"$provenance_raw"
[ "${#provenance_list[@]}" -gt 0 ] \
	|| die "the provenance file set is empty (Makefile RELEASE_PROVENANCE_FILES)"
# Parsed in bash rather than through awk: this script deliberately depends on
# make, python3 and coreutils and nothing else, and SHA256SUMS is committed
# input to a privileged workflow. One pass, strict form, duplicates rejected.
declare -A listed_digest=()
sums_line_no=0
while IFS= read -r line || [ -n "$line" ]; do
	sums_line_no=$((sums_line_no + 1))
	[[ "$line" != *$'\r'* ]] \
		|| die "SHA256SUMS line $sums_line_no contains a carriage return"
	[[ "$line" =~ ^([0-9a-f]{64})\ [\ *]([^/]+)$ ]] \
		|| die "malformed SHA256SUMS line $sums_line_no: $line"
	sums_name=${BASH_REMATCH[2]}
	[ -z "${listed_digest[$sums_name]+set}" ] \
		|| die "SHA256SUMS lists $sums_name more than once"
	listed_digest[$sums_name]=${BASH_REMATCH[1]}
done < "$checksums"
for provenance_base in "${provenance_list[@]}"; do
	[ -n "${listed_digest[$provenance_base]+set}" ] \
		|| die "$provenance_base is not covered by SHA256SUMS; the release signature does not reach its own provenance"
	actual=$(sha256sum -- "$release_dir/$provenance_base") \
		|| die "could not hash $provenance_base"
	[ "${actual%% *}" = "${listed_digest[$provenance_base]}" ] \
		|| die "$provenance_base does not hash to the value SHA256SUMS records for it"
done

# --- the per-release README states the same release as QUALIFICATION ---------
# Until v0.9.12 nothing read this file. It is the first thing a recipient opens,
# it names the version and carries the shortened-soak banner, and a wrong
# version or a missing banner here contradicts the machine record while every
# gate stayed green. It is checked exactly as MANIFEST.md is, against the same
# authority, because it makes the same claims to a less careful reader.
grep -Fxq "# $expected_version" "$readme" \
	|| die "README.md heading does not match QUALIFICATION version $expected_version"
case "${q[release_mode]}" in
	production)
		if grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$readme"; then
			die "production README.md contains the dry-run banner"
		fi
		if grep -Fq "$EXPRESS_BANNER" "$readme"; then
			die "production README.md contains the express banner"
		fi
		;;
	express)
		if grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$readme"; then
			die "express README.md contains the dry-run banner"
		fi
		grep -Fq "$EXPRESS_BANNER" "$readme" \
			|| die "express README.md is missing its shortened-soak banner"
		;;
	*)
		grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$readme" \
			|| die "dry-run README.md is missing its warning banner"
		;;
esac

printf 'QUALIFIED: %s records clean %s qualification with %d exact %s-ms soak results, provenance inside the signature.\n' \
	"$expected_version" "${q[release_mode]}" "${#canonical_soaks[@]}" "$duration"
