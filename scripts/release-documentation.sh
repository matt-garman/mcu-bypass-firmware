#!/usr/bin/env bash
# Release metadata helpers. Renderers write only document bytes to stdout; the
# validator reads bounded source documentation without modifying it.

_release_documentation_error() {
	printf 'release documentation: %s\n' "$*" >&2
	return 1
}

_release_current_block() {
	[ "$#" -eq 1 ] || return 2
	awk '
		$0 == "<!-- current-release:start -->" {
			starts++
			if (starts != 1 || current) bad=1
			current=1
			next
		}
		$0 == "<!-- current-release:end -->" {
			ends++
			if (ends != 1 || !current) bad=1
			current=0
			next
		}
		current { print }
		END { exit !(starts == 1 && ends == 1 && !current && !bad) }
	' "$1"
}

release_validate_current_documentation() {
	[ "$#" -eq 4 ] || return 2
	local repo_root=$1 version=$2 image_count=$3 soak_count=$4
	local release_number=${version#v} changelog="$repo_root/CHANGELOG.md"
	local document block contract_line section_count previous_version link_count
	local transition_line referenced
	local -a current_documents=(
		"$repo_root/release/README.md"
		"$repo_root/TODO.md"
		"$repo_root/docs/pic10f320_special_case.md"
		"$repo_root/docs/pic10f320_validation.md"
	)

	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "requested version is not vX.Y.Z: $version" || return
	[[ "$image_count" =~ ^[1-9][0-9]*$ && "$soak_count" =~ ^[1-9][0-9]*$ ]] \
		|| _release_documentation_error "canonical image/soak counts are invalid" || return
	[ -f "$changelog" ] && [ -s "$changelog" ] && [ ! -L "$changelog" ] \
		|| _release_documentation_error "CHANGELOG.md is not a regular nonempty file" || return

	section_count=$(awk -v release="$release_number" '
		/^## \[[^]]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			if (name == release) count++
		}
		END { print count + 0 }
	' "$changelog") || return
	[ "$section_count" -eq 1 ] \
		|| _release_documentation_error "CHANGELOG.md must contain one dated [$release_number] section" || return
	if ! awk -v release="$release_number" '
		$0 == "## [Unreleased]" {
			unreleased++
			waiting=1
			next
		}
		/^## \[[^]]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			if (waiting) {
				first_after_unreleased=name
				waiting=0
			}
			current=(name == release)
			if (current) requested++
			next
		}
		current && /^### (Added|Changed|Deprecated|Removed|Fixed|Security)$/ { categories++ }
		current && /^- / { entries++ }
		END {
			exit !(unreleased == 1 && first_after_unreleased == release \
				&& requested == 1 && categories > 0 && entries > 0)
		}
	' "$changelog"; then
		_release_documentation_error "CHANGELOG.md must put one nonempty dated [$release_number] section immediately after one Unreleased heading" || return
	fi

	previous_version=$(awk -v heading="## [$release_number] - " '
		index($0, heading) == 1 { current=1; next }
		current && /^## \[[^]]+\] - / {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			print "v" name
			exit
		}
	' "$changelog") || return
	[[ "$previous_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "CHANGELOG.md [$release_number] section has no preceding-release section" || return
	link_count=$(grep -Fxc "[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/$version...HEAD" "$changelog" || true)
	[ "$link_count" -eq 1 ] \
		|| _release_documentation_error "CHANGELOG.md has no exact $version...HEAD Unreleased link" || return
	link_count=$(grep -Fxc "[$release_number]: https://github.com/matt-garman/mcu-bypass-firmware/compare/$previous_version...$version" "$changelog" || true)
	[ "$link_count" -eq 1 ] \
		|| _release_documentation_error "CHANGELOG.md has no exact $previous_version...$version release link" || return

	contract_line="**Current release contract:** \`$version\`; seven release parts; $image_count images; $soak_count soak combinations; six modular targets; four shell source files."
	# A bounded declaration states the SOURCE contract; retained evidence lives
	# in a release directory that a source commit provably cannot carry. The cut
	# creates release/<version>/, and scripts/verify-release-history.sh rejects a
	# release whose qualified source commit already contains
	# release/<version>/QUALIFICATION -- so between source finalization and the
	# artifact commit the declared version's directory legitimately does not
	# exist. A block may name it during that window only alongside the exact line
	# that says when it starts to exist. EVERY OTHER release directory a block
	# names is evidence claimed to be retained now and must be present, so an
	# abandoned or postponed release cannot leave a declaration standing on main
	# that points at nothing.
	transition_line="**Pre-tag transition:** \`release/$version/\` is created by the release cut and published with the signed \`$version\` tag, so the source tree that declares this contract does not contain it yet."
	for document in "${current_documents[@]}"; do
		[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
			|| _release_documentation_error "designated current-release document is not a regular nonempty file: ${document#$repo_root/}" || return
		if ! block=$(_release_current_block "$document"); then
			_release_documentation_error "${document#$repo_root/} must contain one bounded current-release block" || return
		fi
		link_count=$(awk '{ sub(/^>[[:space:]]*/, ""); print }' <<<"$block" \
			| grep -Fxc "$contract_line" || true)
		[ "$link_count" -eq 1 ] \
			|| _release_documentation_error "${document#$repo_root/} must contain the exact current release contract: $contract_line" || return
		while IFS= read -r referenced; do
			[ -n "$referenced" ] || continue
			if [ -d "$repo_root/release/$referenced" ]; then
				continue
			fi
			if [ "$referenced" != "$version" ]; then
				_release_documentation_error "${document#$repo_root/} declares retained evidence under release/$referenced/, which this tree does not contain" || return
			fi
			link_count=$(awk '{ sub(/^>[[:space:]]*/, ""); print }' <<<"$block" \
				| grep -Fxc "$transition_line" || true)
			[ "$link_count" -eq 1 ] \
				|| _release_documentation_error "${document#$repo_root/} names the not-yet-staged release/$version/ and must carry the exact pre-tag transition line: $transition_line" || return
		done < <(grep -oE 'release/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?/' <<<"$block" \
			| sed -e 's#^release/##' -e 's#/$##' | sort -u)
	done
}

# Bind the bounded current-release declarations to the inventory that was
# actually STAGED, not to the canonical Makefile set that predicted it.
# release_validate_current_documentation runs before any build, so the strongest
# statement it can make is that four documents agree with what the Makefile says
# a release will contain. This one runs on the staged directory and closes the
# loop a human would otherwise close by eye: "21 images; 18 soak combinations"
# in four documents against 21 files and 18 soak records on disk. It is the last
# documentation check before the artifact commit and the tag.
release_validate_staged_documentation() {
	[ "$#" -eq 3 ] || return 2
	local repo_root=$1 release_dir=$2 version=$3
	local evidence_dir="$release_dir/evidence" path
	local -a staged_images=() staged_soaks=()

	[ -d "$release_dir" ] \
		|| _release_documentation_error "staged release directory not found: $release_dir" || return
	[ -d "$evidence_dir" ] \
		|| _release_documentation_error "staged release directory retains no evidence/: $release_dir" || return

	while IFS= read -r -d '' path; do
		[ -n "$path" ] && staged_images+=("$path")
	done < <(find "$release_dir" -maxdepth 1 -type f -name '*.hex' -print0)
	# A soak combination is identified by the machine record its log carries, not
	# by a filename pattern: evidence/ also retains build and aggregate logs, and
	# soak-build.log would match any name-based count.
	while IFS= read -r -d '' path; do
		[ -n "$path" ] && staged_soaks+=("$path")
	done < <(find "$evidence_dir" -maxdepth 1 -type f \
		-exec grep -lZ '^SOAK_RESULT ' {} +)

	[ "${#staged_images[@]}" -gt 0 ] \
		|| _release_documentation_error "staged release directory contains no images: $release_dir" || return
	[ "${#staged_soaks[@]}" -gt 0 ] \
		|| _release_documentation_error "staged release directory retains no soak records: $release_dir" || return

	release_validate_current_documentation "$repo_root" "$version" \
		"${#staged_images[@]}" "${#staged_soaks[@]}" || return
}

# Reject a release cut from a tree that still contains -- or still references --
# a branch-only working document. Two kinds must fail, for different reasons:
#
#   * A KNOWN branch-only name: root-level `v*-polish.md` (e.g. v0.9.9-polish.md)
#     or root-level `pre-v*-fixes.md` (a pre-release fix list). Such a document
#     exists ONLY on a branch and must be deleted, and de-referenced, in the
#     final pre-merge commit; a production release is cut from main, so none may
#     remain.
#   * ANY other root-level Markdown document outside the durable set below.
#     Adding one name pattern per working document is precisely how this gate
#     came to miss `pre-v*-fixes.md`, so the root document set is an allowlist
#     rather than a blocklist: the durable documents ship, and any other
#     root-level document fails the release until it is deleted -- or added to
#     the set here, deliberately, because it now ships too.
#
# The reference half necessarily stays name-pattern based: once a document is
# deleted, its name is the only thing left to search for.
#
# Deliberately SEPARATE from release_validate_current_documentation: that
# validator runs in `--preflight`, which exercises the live checked-in tree
# (where a working document legitimately still exists during branch work). This
# gate is invoked only on the actual release-staging path, after preflight has
# exited, so it fails a real release closed without breaking the preflight
# capability probe. The retained docs/v0.9.6_post_release_polish.md is under
# docs/, not root-level, so it is unaffected.
release_reject_branch_only_documents() {
	[ "$#" -eq 1 ] || return 2
	local repo_root=$1 root_doc label durable_doc durable reference_file
	local find_pid grep_output grep_status
	local -a present_branch_docs=() undeclared_root_docs=() branch_doc_references=()
	# Every root-level Markdown document a release is allowed to ship.
	local -a durable_root_docs=(
		AGENTS.md
		CHANGELOG.md
		CLAUDE.md
		FLASHING.md
		HARDWARE_VALIDATION_LOG.md
		MISRA_COMPLIANCE.md
		README.md
		TODO.md
	)

	while IFS= read -r -d '' root_doc; do
		[ -n "$root_doc" ] || continue
		label=${root_doc#$repo_root/}
		case "$label" in
			v*-polish.md|pre-v*-fixes.md)
				present_branch_docs+=("$label")
				continue
				;;
		esac
		durable=0
		for durable_doc in "${durable_root_docs[@]}"; do
			if [ "$label" = "$durable_doc" ]; then
				durable=1
				break
			fi
		done
		if [ "$durable" -eq 0 ]; then
			undeclared_root_docs+=("$label")
		fi
	done < <(find "$repo_root" -maxdepth 1 -type f -name '*.md' -print0)
	find_pid=$!
	wait "$find_pid" \
		|| _release_documentation_error "could not scan for branch-only working documents" || return
	[ "${#present_branch_docs[@]}" -eq 0 ] \
		|| _release_documentation_error "branch-only working document(s) must be deleted before release: ${present_branch_docs[*]}" || return
	[ "${#undeclared_root_docs[@]}" -eq 0 ] \
		|| _release_documentation_error "root-level document(s) outside the durable root-document set must be deleted before release, or added to that set in release-documentation.sh if they now ship: ${undeclared_root_docs[*]}" || return

	# A durable file that still NAMES such a document (v<ver>-polish.md or
	# pre-v<ver>-fixes.md) dangles once it is deleted. Exclude this checker and
	# its regression, which necessarily carry the patterns as tooling -- the same
	# self-reference the Makefile name contract allowlists.
	if grep_output=$(grep -rlIE 'v[0-9][0-9.]*-polish\.md|pre-v[0-9][0-9.]*-fixes\.md' "$repo_root" \
		--exclude-dir=.git \
		--exclude='release-documentation.sh' \
		--exclude='test_release_preflight.sh'); then
		while IFS= read -r reference_file; do
			[ -n "$reference_file" ] && branch_doc_references+=("${reference_file#$repo_root/}")
		done <<<"$grep_output"
	else
		grep_status=$?
		[ "$grep_status" -eq 1 ] \
			|| _release_documentation_error "could not scan for branch-only working-document references" || return
	fi
	[ "${#branch_doc_references[@]}" -eq 0 ] \
		|| _release_documentation_error "durable file(s) still reference a branch-only working document (repoint to CHANGELOG.md / Git history): ${branch_doc_references[*]}" || return
}

# Blank every Markdown code span and every double-quoted span, so a phrase a
# document merely NAMES cannot be mistaken for a phrase it asserts.
_release_unquoted_prose() {
	[ "$#" -eq 1 ] || return 2
	sed -e 's/`[^`]*`/ /g' -e 's/"[^"]*"/ /g' -- "$1"
}

# Extract one bounded section of HARDWARE_VALIDATION_LOG.md by marker name.
_release_hardware_block() {
	[ "$#" -eq 2 ] || return 2
	awk -v marker="$1" '
		$0 == "<!-- " marker ":start -->" {
			starts++
			if (starts != 1 || inside) bad=1
			inside=1
			next
		}
		$0 == "<!-- " marker ":end -->" {
			ends++
			if (ends != 1 || !inside) bad=1
			inside=0
			next
		}
		inside { print }
		END { exit !(starts == 1 && ends == 1 && !inside && !bad) }
	' "$2"
}

# Keep the two kinds of hardware evidence this project holds from being read as
# one kind.
#
# HARDWARE_VALIDATION_LOG.md carries both. Section 1 is self-reported community
# field use: real parts, real circuits, and no retained image identity,
# procedure or measurement. Section 2 is controlled project qualification, which
# no part has yet. Before v0.9.10 the file presented the first AS the second --
# "which firmware has been flashed-to and tested on actual hardware" over a table
# of forum links -- while CHANGELOG.md, DESIGN_DOCUMENTATION.adoc, TODO.md, the
# Makefile and two design documents simultaneously said no part had ever run on
# a chip. Both statements were wrong, in opposite directions, and a reader could
# take whichever suited them.
#
# Three properties, one per way the reconciliation can rot:
#
#   1. STRUCTURE. Both sections exist, exactly once, in order, and every table
#      row naming a part sits inside one of them. A hardware claim written into
#      loose prose is unclassified by construction, which is the original defect
#      reappearing rather than a formatting lapse.
#   2. RECORD CONTRACT. Section 2 defines every field a controlled record must
#      retain, and then either declares that no record exists or holds records
#      that each carry all of those fields. So the first record anyone writes
#      cannot be a field report wearing a qualification heading -- the exact
#      substitution this split exists to prevent -- and the declaration cannot
#      sit above a record contradicting it.
#   3. VOCABULARY. No durable document uses the "run on silicon / run on a part"
#      idiom in either polarity, and none restates the retired unqualified
#      interchangeability sentence. The idiom is what cannot be true and false at
#      once: field use makes its negation false, and its affirmation claims the
#      qualification nobody performed. Saying anything accurate here requires the
#      words "field-use report" and "controlled hardware qualification", so the
#      idiom's absence is a sound mechanical proxy for the distinction being
#      drawn. The interchangeability sentence is pinned by its exact retired
#      wording because that is what a revert restores.
#
# Scanned on the LIVE tree from --preflight, so a drifted claim fails during
# branch work rather than inside a shipped release. Shipped release/vX.Y.Z/
# directories are immutable artifacts of past releases and are pruned; so are the
# root-level branch-only working documents, which quote retired wording in order
# to describe retiring it.
release_validate_hardware_claims() {
	[ "$#" -eq 1 ] || return 2
	local repo_root=$1
	local log="$repo_root/HARDWARE_VALIDATION_LOG.md"
	local block pin_block record heading structure document label field required
	local find_pid rc=0 record_count
	local sentinel='**No controlled hardware-qualification record exists for any part.**'
	# The definition of "controlled hardware qualification" as this project uses
	# the term. A run missing any one of these is a field-use report, however
	# careful, because a later reader can neither reproduce it nor bound what it
	# did not cover.
	local -a required_fields=(Date Operator "Source commit" Image Part Board \
		Programmer Configuration Procedure Observations Result)
	local -a idiom_offenders=() interchange_offenders=()
	# Either polarity of the conflated idiom, and the retired sentence verbatim.
	local retired_idiom='run on (silicon|a part|a device|the part)'
	local retired_interchange='pinout and can be used interchangeably'

	[ -f "$log" ] && [ -s "$log" ] && [ ! -L "$log" ] \
		|| _release_documentation_error "HARDWARE_VALIDATION_LOG.md is not a regular nonempty file" || return

	structure=$(awk '
		$0 == "<!-- field-reports:start -->" {
			field_starts++
			if (!bad && (field_starts != 1 || in_field || in_controlled)) bad="field-reports:start is duplicated or nested"
			in_field=1
			next
		}
		$0 == "<!-- field-reports:end -->" {
			field_ends++
			if (!bad && (field_ends != 1 || !in_field)) bad="field-reports:end is duplicated or unopened"
			in_field=0
			next
		}
		$0 == "<!-- controlled-qualification:start -->" {
			controlled_starts++
			if (!bad && (controlled_starts != 1 || field_ends != 1 || in_field || in_controlled)) bad="controlled-qualification:start is duplicated, nested, or precedes the field-report section"
			in_controlled=1
			next
		}
		$0 == "<!-- controlled-qualification:end -->" {
			controlled_ends++
			if (!bad && (controlled_ends != 1 || !in_controlled)) bad="controlled-qualification:end is duplicated or unopened"
			in_controlled=0
			next
		}
		/^\| *(ATtiny|PIC1[02]F)/ {
			if (!in_field && !in_controlled && !bad) \
				bad="a part row sits outside both sections and is therefore unclassified: " $0
		}
		END {
			if (!bad && (field_starts != 1 || field_ends != 1 \
					|| controlled_starts != 1 || controlled_ends != 1)) \
				bad="both bounded sections must appear exactly once"
			if (!bad && (in_field || in_controlled)) bad="a bounded section is unterminated"
			if (bad) print bad
		}
	' "$log") || _release_documentation_error "HARDWARE_VALIDATION_LOG.md could not be scanned" || return
	[ -z "$structure" ] \
		|| _release_documentation_error "HARDWARE_VALIDATION_LOG.md classification is broken: $structure" || return

	block=$(_release_hardware_block controlled-qualification "$log") \
		|| _release_documentation_error "HARDWARE_VALIDATION_LOG.md has no bounded controlled-qualification section" || return
	for field in "${required_fields[@]}"; do
		grep -Fq -- "- **$field**" <<<"$block" \
			|| _release_documentation_error "controlled-qualification section does not define the required record field: $field" || rc=1
	done

	if grep -Fxq -- "$sentinel" <<<"$block"; then
		# The declaration and a record cannot both stand.
		if grep -Eq '^### ' <<<"$block"; then
			_release_documentation_error "controlled-qualification section declares that no record exists while carrying one" || rc=1
		fi
		if grep -Eq '^\| *(ATtiny|PIC1[02]F)' <<<"$block"; then
			_release_documentation_error "controlled-qualification section declares that no record exists while tabulating a part" || rc=1
		fi
	else
		record_count=$(grep -Ec '^### ' <<<"$block" || true)
		if [ "$record_count" -eq 0 ]; then
			_release_documentation_error "controlled-qualification section neither declares that no record exists nor carries one" || rc=1
		fi
		while IFS= read -r heading; do
			[ -n "$heading" ] || continue
			record=$(awk -v want="$heading" '
				$0 == want { seen++; if (seen == 1) { keep=1; next } }
				keep && /^### / { exit }
				keep { print }
			' <<<"$block")
			for field in "${required_fields[@]}"; do
				grep -Fq -- "**$field**" <<<"$record" \
					|| _release_documentation_error "controlled-qualification record \"${heading#'### '}\" omits the required field: $field" || rc=1
			done
		done < <(grep -E '^### ' <<<"$block" || true)
	fi

	# Pin compatibility is a BOARD property. The retired note said the AVR classic
	# parts and the PIC10F32x parts "can be used interchangeably", full stop,
	# which reads as firmware and programming interchangeability and is false in
	# both cases: each part needs its own image, and the AVR trio needs different
	# fuse bytes for its different clock while the PIC pair carries CONFIG inside
	# each part's own HEX. Require the qualification to name both families and
	# both mechanisms.
	pin_block=$(awk '
		/^### On pin compatibility$/ { keep=1; next }
		keep && /^#{1,3} / { exit }
		keep { print }
	' "$log") || _release_documentation_error "HARDWARE_VALIDATION_LOG.md could not be scanned for its pin-compatibility section" || return
	[ -n "$pin_block" ] \
		|| _release_documentation_error "HARDWARE_VALIDATION_LOG.md has no nonempty \"On pin compatibility\" section" || rc=1
	for required in ATtiny13a PIC10F320 'own image' fuse CONFIG; do
		grep -Fq -- "$required" <<<"$pin_block" \
			|| _release_documentation_error "pin-compatibility section does not qualify interchangeability with: $required" || rc=1
	done

	while IFS= read -r -d '' document; do
		label=${document#$repo_root/}
		case "$label" in
			v*-polish.md|pre-v*-fixes.md) continue ;;
		esac
		# NAMING the retired wording is not USING it. A document that writes
		# `run on silicon` or "run on silicon" is quoting a phrase in order to
		# retire it -- which CHANGELOG.md, test/README.md and this file all have
		# to do -- while a document that writes it bare is making the claim. So
		# code spans and quoted spans are blanked before matching, and only the
		# surviving prose counts. The first grep is the fast path and the binary
		# guard; the second decides.
		if grep -EIqi -- "$retired_idiom" "$document" \
				&& _release_unquoted_prose "$document" \
					| grep -Eqi -- "$retired_idiom"; then
			idiom_offenders+=("$label")
		fi
		if grep -FIqi -- "$retired_interchange" "$document" \
				&& _release_unquoted_prose "$document" \
					| grep -Fqi -- "$retired_interchange"; then
			interchange_offenders+=("$label")
		fi
	done < <(find "$repo_root" \
		\( -name .git -o -path "$repo_root/release/v[0-9]*" \) -prune -o \
		-type f \( -name '*.md' -o -name '*.adoc' -o -name 'Makefile' \) -print0)
	find_pid=$!
	# A failed scan is a policy failure, not an empty result set.
	wait "$find_pid" \
		|| _release_documentation_error "could not scan durable documentation for retired hardware wording" || return
	[ "${#idiom_offenders[@]}" -eq 0 ] \
		|| _release_documentation_error "durable file(s) still use the conflated \"run on silicon\" idiom; say \"field-use report\" or \"controlled hardware qualification\" (HARDWARE_VALIDATION_LOG.md): ${idiom_offenders[*]}" || rc=1
	[ "${#interchange_offenders[@]}" -eq 0 ] \
		|| _release_documentation_error "durable file(s) restate the retired unqualified interchangeability sentence; pin compatibility is not image/fuse/CONFIG compatibility: ${interchange_offenders[*]}" || rc=1

	return "$rc"
}

# Every PUBLISHED PIC12F675 finalization command must carry the complete identity
# of the transaction it recovers.
#
# `make pic12f675-finalize` is read-only recovery of a PENDING transaction, and it
# passes the CALLER-selected identity to the recovery oracle, which compares it
# against the identity the reservation recorded. A transaction reserved by
# pic12f675-release-program records the release tag and its source commit; one
# reserved by pic12f675-program records neither. So the rule is not "always pass
# the release tag" but "pass the identity of the goal that reserved it", and the
# two directions fail in opposite ways:
#
#   * a signed-release example that OMITS PIC12F675_RELEASE_TAG rejects the very
#     transaction it claims to recover (this is exactly what README.md and
#     release/README.md published before v0.9.10, while the generated per-release
#     documentation carried the argument -- the drift this contract exists to
#     prevent); and
#   * a development example that ADDS it rejects a reservation that holds no
#     release identity.
#
# Each finalization command is therefore anchored to the nearest programming
# command published before it in the same document, and must repeat that
# command's arguments with the SAME VALUES -- naming the right variables is not
# enough when the published recovery points at a different variant or a different
# result path than the transaction it follows.
#
# A "published command" is a line inside a fenced block that begins a `make`
# invocation, continuations included. Prose that merely names the goal mid
# sentence is not a command and is not checked; test/README.md names all three
# goals that way.
_release_pic12f675_finalization_scan() {
	[ "$#" -eq 1 ] || return 2
	local label=$1
	local line command word name value goal mode='' fenced=0 building=0 found=0 rc=0
	local -a words
	local -a required=(VARIANT PIC12F675_PROG PIC12F675_PROG_KIND \
		PIC12F675_READ_PROG PIC12F675_TRIM_EVIDENCE PIC12F675_BENCH_RESULT)
	local -A given reserved

	command=''
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$building" -eq 0 ] && [[ "$line" == '```'* ]]; then
			fenced=$((1 - fenced))
			continue
		fi
		[ "$fenced" -eq 1 ] || continue
		if [ "$building" -eq 0 ]; then
			[[ "$line" =~ ^[[:space:]]*make([[:space:]]|$) ]] || continue
			building=1
			command=''
		fi
		if [[ "$line" =~ ^(.*)\\[[:space:]]*$ ]]; then
			command+=" ${BASH_REMATCH[1]}"
			continue
		fi
		command+=" $line"
		building=0

		read -r -a words <<<"$command"
		given=()
		goal=''
		for word in ${words[@]+"${words[@]}"}; do
			case "$word" in
				pic12f675-release-program|pic12f675-program|pic12f675-finalize)
					goal=$word
					;;
				[A-Za-z_]*=*)
					name=${word%%=*}
					value=${word#*=}
					value=${value%\"}
					given[$name]=${value#\"}
					;;
			esac
		done
		case "$goal" in
			pic12f675-release-program|pic12f675-program)
				mode=$goal
				reserved=()
				if [ "${#given[@]}" -gt 0 ]; then
					for name in "${!given[@]}"; do
						reserved[$name]=${given[$name]}
					done
				fi
				continue
				;;
			pic12f675-finalize) : ;;
			*) continue ;;
		esac
		found=$((found + 1))

		# Same argument, same VALUE: recovery must select the transaction the
		# preceding command reserved, not merely name the right variables.
		for name in "${required[@]}"; do
			if [ -z "${given[$name]+set}" ]; then
				_release_documentation_error \
					"$label publishes a pic12f675-finalize command without $name" || rc=1
			elif [ "${given[$name]}" != "${reserved[$name]-}" ]; then
				_release_documentation_error \
					"$label recovers with $name=${given[$name]} but the transaction it follows reserved ${reserved[$name]-<nothing>}" || rc=1
			fi
		done
		# The release tag is checked for presence, not text: the generated
		# per-release documentation deliberately embeds the resolved tag in its
		# recovery block so recovery does not depend on a shell variable
		# surviving from the programming block, while the static examples carry
		# the same "$release_tag" both times.
		case "$mode" in
			pic12f675-release-program)
				[ -n "${given[PIC12F675_RELEASE_TAG]:-}" ] \
					|| _release_documentation_error \
						"$label finalizes a pic12f675-release-program transaction without PIC12F675_RELEASE_TAG; that reservation records the release identity, so the published recovery would be rejected" \
					|| rc=1
				;;
			pic12f675-program)
				[ -z "${given[PIC12F675_RELEASE_TAG]+set}" ] \
					|| _release_documentation_error \
						"$label finalizes a pic12f675-program transaction with PIC12F675_RELEASE_TAG; that reservation records no release identity" \
					|| rc=1
				;;
			*)
				_release_documentation_error \
					"$label publishes a pic12f675-finalize command with no preceding pic12f675-program or pic12f675-release-program command to recover" || rc=1
				;;
		esac
	done

	[ "$building" -eq 0 ] \
		|| _release_documentation_error "$label ends inside an unterminated make command" || rc=1
	[ "$found" -gt 0 ] \
		|| _release_documentation_error "$label publishes no pic12f675-finalize command" || rc=1
	return "$rc"
}

release_validate_pic12f675_finalization_document() {
	[ "$#" -eq 2 ] || return 2
	local document=$1 label=$2
	[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
		|| _release_documentation_error "finalization document is not a regular nonempty file: $label" || return
	_release_pic12f675_finalization_scan "$label" < "$document"
}

# Validate every published finalization command in the CURRENT tree, plus the
# generated per-release documentation, against the same oracle.
#
# The two static documents are named because deleting the recovery example from
# either must fail; any other current markdown that publishes such a command is
# DISCOVERED, so a new document is covered the day it is written. Shipped
# release directories (release/vX.Y.Z/) are excluded: they are immutable
# artifacts of past releases, and release/v0.9.9/MANIFEST.md legitimately
# publishes the older unsigned pic12f675-program transaction.
release_validate_pic12f675_finalization() {
	[ "$#" -eq 2 ] || return 2
	local repo_root=$1 version=$2
	local document label rendered find_pid rc=0
	# Always scanned, so deleting the recovery example from either is a failure
	# with a precise diagnostic rather than a silently empty scan.
	local -a publishers=("README.md" "release/README.md")

	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "requested version is not vX.Y.Z: $version" || return

	while IFS= read -r -d '' document; do
		label=${document#$repo_root/}
		case "$label" in
			README.md|release/README.md) continue ;;
			# Root-level working documents quote the defective form of a command
			# while describing the defect; they are deleted before release.
			v*-polish.md|pre-v*-fixes.md) continue ;;
		esac
		# A published command, not a prose mention. This finds a NEW document the
		# day it is written; the two named above are scanned either way, so a
		# command this pattern cannot see still fails inside the scan.
		grep -Eq '^[[:space:]]*make([[:space:]].*)?[[:space:]]pic12f675-finalize([[:space:]]|\\|$)' \
			"$document" || continue
		publishers+=("$label")
	done < <(find "$repo_root" \
		\( -name .git -o -path "$repo_root/release/v[0-9]*" \) -prune -o \
		-type f -name '*.md' -print0)
	find_pid=$!
	# A failed scan is a policy failure, not an empty result set: the two named
	# documents would still be checked and a drifted third would pass unseen.
	wait "$find_pid" \
		|| _release_documentation_error "could not scan for published finalization commands" || return

	for label in "${publishers[@]}"; do
		release_validate_pic12f675_finalization_document "$repo_root/$label" "$label" || rc=1
	done

	rendered=$(release_render_pic12f675_flashing "$version") \
		|| _release_documentation_error "generated PIC12F675 flashing guidance could not be rendered" || return
	_release_pic12f675_finalization_scan "generated release documentation" <<<"$rendered" || rc=1
	return "$rc"
}

# The PIC12F675 flashing contract, checked on the LIVE tree.
#
# This part is the one target where a correct HEX plus a writer is not a
# sufficient instruction: a bulk erase destroys the per-device OSCCAL word and
# the CONFIG BG<1:0> bandgap trim, and a device that loses either still appears
# to work. From v0.9.10 the answer for a downloaded release is the helper this
# repository ships INSIDE the release bundle, and the raw command sequence
# FLASHING.md used to publish is retired.
#
# The failure this exists to prevent already happened once, in the other
# direction: README.md and release/README.md prohibited a raw writer while
# FLASHING.md published one, and the suite was green because only the GENERATED
# per-release guidance was contract-tested. So all four publishers are checked
# together -- the two static documents, the release directory README, and the
# rendered per-release section -- plus a DISCOVERED scan of every other current
# Markdown document, which catches a raw command in a file written tomorrow.
#
# A "raw writer command" is a fenced line that INVOKES a programmer (pk2cmd,
# ipecmd, or java running the IPE jar), names this part, and carries a program
# option. The helper invocation is a `python3` command that merely passes an
# ipecmd path, so it is not one -- which is exactly the distinction a
# substring search for "ipecmd" would get wrong.
# Does one folded command line publish a raw write of this part?
#
# Three independent tokens must all be present, which is what keeps prose that
# NAMES the retired form -- "do not substitute a raw `pk2cmd` command" -- from
# reading as a publication of it:
#
#   1. a WRITER, recognized by the basename of any token, so a full install
#      path, a `sudo`/`env` prefix, a `$IPECMD` variable, `ipecmd.sh`, or a
#      `java -jar .../ipecmd.jar` form is not a way around the check;
#   2. this PART, so the six flash-and-forget parts keep their one-liners; and
#   3. a MUTATING option -- `-M` and its `-MP`/`-ME`/`-MI`/`-MC` selectors, or
#      an erase. A `-GF` export carries none of them and stays publishable:
#      reading a device is how an operator archives its trim, and the helper's
#      own `--ipecmd <path>` invocation names a writer without asking for one.
_release_pic12f675_raw_writer_command() {
	[ "$#" -eq 1 ] || return 2
	local command=$1 token base
	# Splitting the command into tokens must not also glob: `-P*` in a document
	# would otherwise be expanded against the caller's working directory.
	local -
	set -f
	case "$command" in
		*12F675*|*12f675*) ;;
		*) return 1 ;;
	esac
	# Program and erase selectors carry at most one suffix letter (-M, -MP, -ME,
	# -MI, -MC, -E), so the run is bounded: an unbounded [A-Za-z]* would also
	# match an ordinary path component such as /Evidence.
	[[ "$command" =~ (^|[[:space:]])[-/](M[A-Za-z]?|E[A-Za-z]?)([[:space:]]|$) ]] \
		|| return 1
	for token in $command; do
		token=${token%%=*}
		# Quotes come off before the expansion sigils, or "$IPECMD" is left
		# with a leading quote and the sigil strip does nothing.
		token=${token#\"}
		token=${token%\"}
		token=${token#\'}
		token=${token%\'}
		token=${token#\$}
		token=${token#\{}
		token=${token%\}}
		base=${token##*/}
		base=${base##*\\}
		case "${base,,}" in
			pk2cmd|pk2cmd.exe|ipecmd|ipecmd.exe|ipecmd.jar|ipecmd.sh|ipecmd.bat)
				return 0 ;;
		esac
	done
	return 1
}

# Command CONTEXTS, not prose: fenced Markdown blocks, AsciiDoc listing and
# literal blocks, indented code blocks, and inline code spans. A published
# command lives in one of those; a sentence that mentions a tool does not.
_release_pic12f675_raw_writer_scan() {
	[ "$#" -eq 1 ] || return 2
	local label=$1
	local line command span fenced=0 listing=0 building=0 rc=0

	_raw_writer_report() {
		_release_documentation_error \
			"$label publishes a raw PIC12F675 writer command; a downloaded release image must be passed to flash-pic12f675.py, never to the programmer directly:$1" \
			|| rc=1
	}

	command=''
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$building" -eq 0 ] && [ "$listing" -eq 0 ] && [[ "$line" == '```'* ]]; then
			fenced=$((1 - fenced))
			continue
		fi
		if [ "$building" -eq 0 ] && [ "$fenced" -eq 0 ]; then
			# AsciiDoc delimits listing blocks with ---- and literal blocks
			# with .... on their own line.
			case "$line" in
				'----'|'....') listing=$((1 - listing)); continue ;;
			esac
		fi
		if [ "$fenced" -eq 0 ] && [ "$listing" -eq 0 ] && [ "$building" -eq 0 ]; then
			# Outside a block, two contexts still carry commands: an indented
			# code block, and any inline code span on a prose line.
			case "$line" in
				'    '*|$'\t'*)
					_release_pic12f675_raw_writer_command "$line" && _raw_writer_report " $line"
					continue ;;
			esac
			span=$line
			while [[ "$span" == *'`'*'`'* ]]; do
				span=${span#*\`}
				_release_pic12f675_raw_writer_command "${span%%\`*}" \
					&& _raw_writer_report " ${span%%\`*}"
				span=${span#*\`}
			done
			continue
		fi
		[ "$fenced" -eq 1 ] || [ "$listing" -eq 1 ] || [ "$building" -eq 1 ] || continue
		if [ "$building" -eq 0 ]; then
			building=1
			command=''
		fi
		if [[ "$line" =~ ^(.*)\\[[:space:]]*$ ]]; then
			command+=" ${BASH_REMATCH[1]}"
			continue
		fi
		command+=" $line"
		building=0
		_release_pic12f675_raw_writer_command "$command" \
			&& _raw_writer_report "$command"
	done
	[ "$building" -eq 0 ] \
		|| _release_documentation_error "$label ends inside an unterminated programmer command" || rc=1
	unset -f _raw_writer_report
	return "$rc"
}

# Collapse a document to one whitespace-normalized line, so a required sentence
# is found whether or not an editor rewrapped it.
_release_flowed_text() {
	[ "$#" -eq 1 ] || return 2
	tr '\n\t' '  ' < "$1" | tr -s ' '
}

release_validate_pic12f675_flashing_helper() {
	[ "$#" -eq 2 ] || return 2
	local repo_root=$1 version=$2
	local helper_name='flash-pic12f675.py'
	local helper_source='scripts/flash-pic12f675.py'
	local claim='PIC12F675 additionally requires Python 3 and the release'\''s flashing helper because its per-device factory calibration must be preserved and verified.'
	local document label rendered flowed find_pid rc=0
	# Always scanned, so deleting the helper instruction from any of them is a
	# failure with a precise diagnostic rather than a silently empty scan.
	local -a publishers=("README.md" "FLASHING.md" "release/README.md")
	# Universal claims the helper requirement retires. Each was true of the six
	# flash-and-forget parts and false of this one.
	local -a retired_claims=(
		'Needs only a programmer and its CLI'
		'needs no toolchain at all'
		'no build toolchain, no clone of this repository'
	)
	local retired

	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "requested version is not vX.Y.Z: $version" || return

	# 1. The shipped tool itself.
	[ -f "$repo_root/$helper_source" ] && [ ! -L "$repo_root/$helper_source" ] \
		&& [ -s "$repo_root/$helper_source" ] \
		|| _release_documentation_error "the PIC12F675 flashing helper is missing or not a regular file: $helper_source" || return
	[ -x "$repo_root/$helper_source" ] \
		|| _release_documentation_error "the PIC12F675 flashing helper is not executable: $helper_source" || rc=1

	# 2. It is a RELEASE artifact, not merely a file in the tree. Without this
	#    binding the documents below would instruct an operator to use a tool
	#    that no release bundle contains.
	grep -Fq "$helper_name=$helper_source" "$repo_root/Makefile" \
		|| _release_documentation_error "the Makefile does not bind $helper_name to $helper_source as a required release artifact (RELEASE_HELPER_MAP)" || rc=1

	# 3. Every publisher names the helper, and the two entry-point documents
	#    carry the precise claim rather than an implicit escape clause.
	for label in "${publishers[@]}"; do
		document="$repo_root/$label"
		[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
			|| { _release_documentation_error "flashing document is not a regular nonempty file: $label" || rc=1; continue; }
		grep -Fq "$helper_name" "$document" \
			|| _release_documentation_error "$label does not name the release-shipped PIC12F675 flashing helper $helper_name" || rc=1
		flowed=$(_release_flowed_text "$document") || return
		case "$label" in
			README.md|FLASHING.md)
				case "$flowed" in
					*"$claim"*) ;;
					*) _release_documentation_error "$label does not carry the exact downloaded-release programming claim (PIC12F675 additionally requires Python 3 and the flashing helper)" || rc=1 ;;
				esac
				;;
		esac
		for retired in "${retired_claims[@]}"; do
			case "$flowed" in
				*"$retired"*)
					_release_documentation_error "$label still publishes the retired universal claim: $retired" || rc=1 ;;
			esac
		done
		_release_pic12f675_raw_writer_scan "$label" < "$document" || rc=1
	done

	# 4. FLASHING.md says it in its heading, where a reader skimming for the
	#    part actually looks.
	grep -Eq '^#+[[:space:]]+PIC12F675[[:space:]].*not a raw write target' \
		"$repo_root/FLASHING.md" \
		|| _release_documentation_error "the FLASHING.md PIC12F675 heading does not state that it is not a raw write target" || rc=1

	# 5. Any OTHER current document that publishes a raw writer command fails the
	#    day it is written, and any current document -- these three included --
	#    that still says this part has no no-compiler path contradicts them.
	#    Shipped release directories are immutable artifacts of past releases and
	#    legitimately carry retired wording; root-level working documents quote
	#    the defective form while describing the defect.
	#
	#    The superseded states are named as exact sentences rather than matched
	#    by pattern. docs/flashing_simplicity.md legitimately records its own
	#    retired position IN THE PAST TENSE ("The position was that no
	#    no-compiler path ... had been designed"), and a pattern wide enough to
	#    catch the live claim would fail on the record of how it was retired.
	#    Matched case-insensitively, and so spelled in lower case here: the same
	#    sentence at the start of a sentence is the same claim.
	local -a retired_state=(
		'there is not yet a no-compiler path'
		'the one place where a qualified direct-from-download path is not available today'
		'requires a clean source checkout of the same release tag and the pinned xc8/dfp toolchain'
	)
	while IFS= read -r -d '' document; do
		label=${document#$repo_root/}
		case "$label" in
			v*-polish.md|pre-v*-fixes.md) continue ;;
		esac
		flowed=$(_release_flowed_text "$document") || return
		for retired in "${retired_state[@]}"; do
			case "${flowed,,}" in
				*"$retired"*)
					_release_documentation_error "$label still publishes the superseded PIC12F675 state, which the helper retired: $retired" || rc=1 ;;
			esac
		done
		case "$label" in
			README.md|FLASHING.md|release/README.md) continue ;;
		esac
		_release_pic12f675_raw_writer_scan "$label" < "$document" || rc=1
	done < <(find "$repo_root" \
		\( -name .git -o -path "$repo_root/release/v[0-9]*" \) -prune -o \
		-type f \( -name '*.md' -o -name '*.adoc' \) -print0)
	find_pid=$!
	wait "$find_pid" \
		|| _release_documentation_error "could not scan for raw PIC12F675 writer commands" || return

	# 6. The generated per-release guidance, held to the same contract.
	rendered=$(release_render_pic12f675_flashing "$version") \
		|| _release_documentation_error "generated PIC12F675 flashing guidance could not be rendered" || return
	case "$rendered" in
		*"$helper_name"*) ;;
		*) _release_documentation_error "generated release documentation does not name $helper_name" || rc=1 ;;
	esac
	case "$rendered" in
		*'NOT a raw write target'*) ;;
		*) _release_documentation_error "generated release documentation does not state that PIC12F675 is not a raw write target" || rc=1 ;;
	esac
	_release_pic12f675_raw_writer_scan "generated release documentation" <<<"$rendered" || rc=1
	return "$rc"
}

release_render_scope() {
	[ "$#" -eq 0 ] || return 2
	printf 'Release scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT),\n'
	printf 'PIC10F322, PIC10F320, and PIC12F675.\n\n'
}

release_render_validation() {
	[ "$#" -eq 1 ] || return 2
	local hours=$1
	printf -- '- **Validation:** `make test-long` + `make attiny202-test` + `make attiny202-test-target`'
	printf ' + `make pic10f322-test` + `make pic10f322-test-target-variants`'
	printf ' + `make pic10f320-test` + `make pic10f320-test-target-variants`'
	printf ' + `make pic12f675-test pic12f675-test-target-variants` (one retained matrix)'
	printf ' (real-image fault handling, firmware/model ctx_ lock-step, and physical-output checks across AVR-XT and all three PIC parts)'
	printf ' + %s-h parallel soak of every release soak combination (see evidence/).\n' "$hours"
}

release_render_pic_toolchain_rows() {
	[ "$#" -eq 6 ] || return 2
	local pic_cc=$1 shared_xc8_version=$2
	local pic10f320_cc=$3 pic10f320_xc8_version=$4
	local pic_dfp=$5 pic10f320_dfp=$6
	printf -- '| PIC10F322/PIC12F675 XC8 (`PIC_CC=%s`) | %s |\n' \
		"$pic_cc" "$shared_xc8_version"
	printf -- '| PIC10F320 XC8 (`PIC10F320_CC=%s`) | %s |\n' \
		"$pic10f320_cc" "$pic10f320_xc8_version"
	printf -- '| PIC10F322/PIC12F675 DFP (`PIC_DFP`) | %s |\n' "$pic_dfp"
	printf -- '| PIC10F320 DFP (`PIC10F320_DFP`) | %s |\n' "$pic10f320_dfp"
}

release_render_pic12f675_flashing() {
	[ "$#" -eq 1 ] || return 2
	local release_tag=$1
	printf '%s\n' \
		'### PIC12F675 programming' \
		'' \
		'This part is NOT a raw write target. Its per-device factory OSCCAL word and' \
		'CONFIG `BG<1:0>` trim live in memory a programmer erases, and a device that' \
		'loses either still appears to work. Every write therefore goes through a' \
		'guarded transaction, and there are two of them.' \
		'' \
		'**Programming these downloaded images** needs no source checkout and no' \
		'firmware development toolchain -- only Python 3 and MPLAB X 6.20 `ipecmd`.' \
		'Pass the release HEX to `flash-pic12f675.py`, which ships beside the images' \
		'and is covered by the signed `SHA256SUMS` in this release. Externally power the' \
		'board; the helper never requests programmer-supplied Vdd. Choose a NEW' \
		'evidence directory per device.' \
		'' \
		'```sh' \
		'python3 flash-pic12f675.py program \' \
		'  --image bypass-pic12f675-cd4053_simple.hex \' \
		'  --ipecmd /opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.jar \' \
		'  --evidence-dir ./pic12f675-device-001' \
		'```' \
		'' \
		'It checks the image against the signed checksum, refuses an image that programs' \
		'word `0x3FF` or moves the CONFIG BG field, pins the tool version, reads the' \
		'device twice, reserves the write durably, writes exactly once, and publishes one' \
		'immutable PASS/FAIL `result.json`. A PENDING directory -- a reservation with no' \
		'result -- is resolved read-only, and that mode never constructs a writer' \
		'argument:' \
		'' \
		'```sh' \
		'python3 flash-pic12f675.py finalize \' \
		'  --evidence-dir ./pic12f675-device-001 \' \
		'  --ipecmd /opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.jar' \
		'```' \
		'' \
		'A PASS means no trim damage was OBSERVED on that device. It is not proof that' \
		'the writer preserves calibration: that remains hardware-unvalidated until the' \
		'`1.x.y` bench pass, and the helper detects damage only after the write.' \
		'' \
		'#### From a source checkout of this tag (development and release provenance)' \
		'' \
		'Externally power the board; this workflow does not request programmer-supplied Vdd.' \
		'Do not invoke a raw programmer write for this part. For each device, choose' \
		'new baseline and result paths whose parent directory already exists, then run' \
		'the read-only preflight and program steps as one fail-stop transaction. Replace' \
		'`cd4053_simple` with one supported output stage when needed:' \
		'`cd4053_simple`, `cd4053_with_mute`, or `tq2_l2_5v_relay`.' \
		'' \
		'```sh' \
		"release_tag=$(printf '%q' "$release_tag") &&" \
		'repo=$(git rev-parse --show-toplevel) &&' \
		'head_commit=$(git -C "$repo" rev-parse --verify "HEAD^{commit}") &&' \
		'tag_commit=$(git -C "$repo" rev-parse --verify "refs/tags/$release_tag^{commit}") &&' \
		'worktree_status=$(git -C "$repo" status --porcelain=v1 --untracked-files=normal) &&' \
		'test "$head_commit" = "$tag_commit" && test -z "$worktree_status" &&' \
		'evidence_root=$(dirname "$repo") &&' \
		'baseline="$evidence_root/pic12f675-factory-baseline.json" &&' \
		'result="$evidence_root/pic12f675-program-result" &&' \
		'test ! -e "$baseline" && test ! -e "$result" &&' \
		'make -C "$repo" pic12f675-preflight \' \
		'  PIC12F675_READ_PROG=pk2cmd \' \
		'  PIC12F675_TRIM_EVIDENCE="$baseline" &&' \
		'make -C "$repo" pic12f675-release-program \' \
		'  VARIANT=cd4053_simple \' \
		'  PIC12F675_RELEASE_TAG="$release_tag" \' \
		'  PIC12F675_PROG=pk2cmd \' \
		'  PIC12F675_PROG_KIND=pk2cmd \' \
		'  PIC12F675_READ_PROG=pk2cmd \' \
		'  PIC12F675_TRIM_EVIDENCE="$baseline" \' \
		'  PIC12F675_BENCH_RESULT="$result"' \
		'```' \
		'' \
		'If an interruption leaves `reservation.json` but no `result.json`, the' \
		'transaction is **PENDING**. Keep physical custody of the same attached device.' \
		'Do not write, reflash, capture a new baseline, or reuse the result path. From' \
		'this same release checkout, resolve it with the same release identity, variant,' \
		'and tool identities:' \
		'' \
		'```sh' \
		'make -C "$repo" pic12f675-finalize \' \
		'  VARIANT=cd4053_simple \' \
		"  PIC12F675_RELEASE_TAG=$(printf '%q' "$release_tag") \\" \
		'  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \' \
		'  PIC12F675_READ_PROG=pk2cmd \' \
		'  PIC12F675_TRIM_EVIDENCE="$baseline" \' \
		'  PIC12F675_BENCH_RESULT="$result"' \
		'```' \
		'' \
		'Finalization revalidates the same signed release tag and image, every reserved' \
		'identity, and the separately retained image' \
		'before hardware access and never invokes writer arguments. It verifies the reader' \
		'version before a full-device read, uses retry-safe private attempts, and exclusively' \
		'publishes the recovered PASS/FAIL `result.json`; FAIL is a' \
		'resolved forensic record, not permission to retry the write, and an existing result' \
		'is immutable.' \
		'' \
		'The guarded workflow rejects an image that explicitly programs OSCCAL word' \
		'`0x3FF`, requires the image BG field to remain erased, compares the live device' \
		'with the baseline immediately before writing.' \
		'Post-write identity, OSCCAL, BG, CONFIG, and programmed bytes are checked and recorded' \
		'as mandatory evidence.' \
		'This does not prove that a real pk2cmd or ipecmd erase/program operation preserves' \
		'factory trim: preservation remains hardware-unvalidated until the `1.x.y` bench' \
		'pass. A failure is detected only after the write and may already have damaged the device.' \
		'The device may still appear to work with wrong timing or BOR/POR thresholds.' \
		'The release target rechecks a clean checkout of this exact annotated release tag,' \
		'verifies the pinned tag and checksum signatures, and requires the private fresh' \
		'build to match the selected digest in the complete signed release image set.' \
		'It does not consume a downloaded release HEX. Baseline and result evidence stay' \
		'outside the worktree so those checks remain exact. Transient reads and the private build use `TMPDIR` when set,' \
		'otherwise `XDG_RUNTIME_DIR`, otherwise `HOME`. The selected root must exist, be' \
		'current-user-private, and have only root/current-user-owned non-writable ancestors.' \
		'Shared `/tmp` and `/var/tmp` roots are rejected; the path is limited to letters,' \
		'digits, spaces, `/`, `.`, `_`, and `-`.' \
		'Handled exits remove the transient directories. No ipecmd hardware' \
		'procedure is qualified: its software-tested write route would also require a' \
		'pk2cmd reader before and after the write, and no safe attachment/handoff has been' \
		'validated.' \
		''
}

release_render_flashing() {
	[ "$#" -eq 2 ] || return 2
	local flash_commands=$1 release_tag=$2 image command
	[ -s "$flash_commands" ] && [ -f "$flash_commands" ] \
		&& [ ! -L "$flash_commands" ] || return 2
	while IFS=$'\t' read -r image command; do
		[ -n "$image" ] && [ -n "$command" ] || return 2
		case "$image" in
			*-pic12f675-*.hex) return 2 ;;
		esac
	done < "$flash_commands"

	printf '%s\n' \
		'## Flashing' \
		'' \
		'AVR images require the design fuse bytes in addition to the flash write' \
		'(the table above lists them per image). PIC images embed their CONFIG word.' \
		'PIC12F675 has no per-image shortcut because every write requires the guarded' \
		'device-specific transaction below -- pass its HEX to the' \
		'`flash-pic12f675.py` shipped in this release, never directly to a programmer.' \
		'' \
		'```'
	sort "$flash_commands" | while IFS=$'\t' read -r image command; do
		printf '# %s\n%s\n\n' "$image" "$command"
	done
	printf '```\n\n'
	release_render_pic12f675_flashing "$release_tag"
}

release_render_reproduction_commands() {
	[ "$#" -eq 11 ] || return 2
	local version=$1 release_image_dirs=$2
	local avr_build_dir=$3 xt_build_dir=$4 pic10f322_build_dir=$5
	local pic10f320_build_dir=$6 pic12f675_build_dir=$7
	local pic_cc=$8 pic_dfp=$9 pic10f320_cc=${10} pic10f320_dfp=${11} dir i
	local -a dirs expected_dirs
	read -r -a dirs <<<"$release_image_dirs"
	expected_dirs=("$avr_build_dir" "$xt_build_dir" "$pic10f322_build_dir" \
		"$pic10f320_build_dir" "$pic12f675_build_dir")
	[ "${#dirs[@]}" -eq "${#expected_dirs[@]}" ] || return 2
	for i in "${!dirs[@]}"; do
		[ "${dirs[$i]}" = "${expected_dirs[$i]}" ] || return 2
	done

	printf 'git checkout %q\n' "$version"
	printf '# install the pinned toolchain (see TOOLCHAIN.adoc), then:\n'
	printf 'make clean AVR_BUILD_DIR=%q XT_BUILD_DIR=%q' \
		"$avr_build_dir" "$xt_build_dir"
	printf ' PIC10F322_BUILD_DIR=%q PIC10F320_BUILD_DIR=%q PIC12F675_BUILD_DIR=%q\n' \
		"$pic10f322_build_dir" "$pic10f320_build_dir" "$pic12f675_build_dir"
	printf 'make attiny13a attiny85 attiny45 AVR_BUILD_DIR=%q\n' "$avr_build_dir"
	printf 'make attiny202 XT_BUILD_DIR=%q STRICT_TOOLS=1\n' "$xt_build_dir"
	printf 'make pic10f322 PIC10F322_BUILD_DIR=%q PIC_CC=%q PIC_DFP=%q\n' \
		"$pic10f322_build_dir" "$pic_cc" "$pic_dfp"
	printf 'make pic10f320-variants PIC10F320_BUILD_DIR=%q' "$pic10f320_build_dir"
	printf ' PIC10F320_CC=%q PIC10F320_DFP=%q\n' "$pic10f320_cc" "$pic10f320_dfp"
	printf 'make pic12f675 PIC12F675_BUILD_DIR=%q PIC_CC=%q PIC_DFP=%q\n' \
		"$pic12f675_build_dir" "$pic_cc" "$pic_dfp"
	printf 'scripts/verify-release-images.sh %q' "release/$version"
	for dir in "${dirs[@]}"; do printf ' %q' "$dir"; done
	printf '\n'
}

release_render_commit_message() {
	[ "$#" -eq 5 ] || return 2
	local version=$1 release_mode=$2 git_short=$3 image_count=$4 hours=$5
	local release_description

	case "$release_mode" in
		dry-run)
			release_description='Non-publishable dry-run rehearsal images'
			;;
		production)
			release_description='Prebuilt, fully-validated firmware images'
			;;
		*)
			return 2
			;;
	esac
	printf 'release: firmware %s\n\n' "$version"
	printf '%s for %s.\n\n' "$release_description" "$version"
	printf 'Built from %s with the toolchain pinned in TOOLCHAIN.adoc.\n' "$git_short"
	printf 'Scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT), PIC10F322,\n'
	printf 'PIC10F320, and PIC12F675 -- %d images, checked against the canonical RELEASE_IMAGES set the\n' \
		"$image_count"
	printf 'Makefile declares rather than against whatever the build produced.\n\n'
	printf 'Validation: make test-long + make attiny202-test + make attiny202-test-target\n'
	printf '+ make pic10f322-test + make pic10f322-test-target-variants\n'
	printf '+ make pic10f320-test + make pic10f320-test-target-variants\n'
	printf '+ make pic12f675-test pic12f675-test-target-variants (one retained matrix)\n'
	printf '+ %s-h parallel soak of every release soak combination (evidence under\n' "$hours"
	printf 'release/%s/evidence/).\n\n' "$version"
	printf 'Reproducibility is pinned by release/%s/SHA256SUMS and verified on a\n' "$version"
	printf 'clean runner by .github/workflows/release.yml when the tag is pushed.\n'
}
