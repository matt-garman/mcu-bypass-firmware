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

# The one spelling of the pre-tag disclosure. Two rules read it -- the release
# preflight that requires it of a block naming its own not-yet-staged release
# directory, and the development-state gate below that requires it of any tree
# declaring a release whose retained record is absent -- and a disclosure the
# two spelled differently would be a rule that silently stopped matching.
_release_transition_line() {
	[ "$#" -eq 1 ] || return 2
	printf '**Pre-tag transition:** `release/%s/` is created by the release cut and published with the signed `%s` tag, so the source tree that declares this contract does not contain it yet.\n' \
		"$1" "$1"
}

release_validate_current_documentation() {
	[ "$#" -ge 4 ] && [ "$#" -le 5 ] || return 2
	local repo_root=$1 version=$2 image_count=$3 soak_count=$4
	local allow_unreleased=${5:-0}
	local release_number=${version#v} changelog="$repo_root/CHANGELOG.md"
	local document block contract_line section_count previous_version link_count
	local transition_line referenced release_heading dated_heading unreleased_heading
	# ONE human authority for the release contract. It was four documents, then
	# two, and every copy was correct only because this validator held all of
	# them to the same canonical counts -- controlled duplication is still
	# duplication, and it made release topology a multi-place hand edit whose
	# copies drifted in the parts no gate compared. release/README.md keeps it
	# because a reader who needs the topology is already reading the release
	# document; everything else points there.
	local -a current_documents=(
		"$repo_root/release/README.md"
	)

	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "requested version is not vX.Y.Z: $version" || return
	[[ "$image_count" =~ ^[1-9][0-9]*$ && "$soak_count" =~ ^[1-9][0-9]*$ ]] \
		|| _release_documentation_error "canonical image/soak counts are invalid" || return
	case "$allow_unreleased" in
		0|1) ;;
		*) _release_documentation_error "allow-unreleased mode must be 0 or 1" || return ;;
	esac
	[ -f "$changelog" ] && [ -s "$changelog" ] && [ ! -L "$changelog" ] \
		|| _release_documentation_error "CHANGELOG.md is not a regular nonempty file" || return

	dated_heading=$(awk -v release="$release_number" '
		/^## \[[^]]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			if (name == release) print
		}
	' "$changelog") || return
	unreleased_heading=$(grep -Fx "## [$release_number] - Unreleased" "$changelog" || true)
	section_count=$(printf '%s\n%s\n' "$dated_heading" "$unreleased_heading" \
		| grep -c '^## ' || true)
	[ "$section_count" -eq 1 ] \
		|| _release_documentation_error "CHANGELOG.md must contain exactly one dated or explicitly Unreleased [$release_number] section" || return
	if [ -n "$unreleased_heading" ]; then
		[ "$allow_unreleased" -eq 1 ] \
			|| _release_documentation_error "CHANGELOG.md [$release_number] is still Unreleased; production requires a dated heading" || return
		release_heading=$unreleased_heading
	else
		release_heading=$dated_heading
	fi
	if ! awk -v release="$release_number" -v release_heading="$release_heading" '
		$0 == "## [Unreleased]" {
			unreleased++
			waiting=1
			next
		}
		/^## \[[^]]+\] - ([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|Unreleased)$/ {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			if (waiting) {
				first_after_unreleased=name
				waiting=0
			}
			current=($0 == release_heading)
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
		_release_documentation_error "CHANGELOG.md must put one nonempty [$release_number] section immediately after one Unreleased heading" || return
	fi

	previous_version=$(awk -v heading="$release_heading" '
		$0 == heading { current=1; next }
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
	transition_line=$(_release_transition_line "$version")
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

	_release_reject_extra_current_blocks "$repo_root" \
		"${current_documents[0]#$repo_root/}"
}

# The declaration is singular, and stays singular.
#
# The set above is one document. This is what keeps it one: a bounded block
# written into any OTHER current document fails here, named, on the day it is
# written, rather than quietly becoming the next copy someone has to remember
# on every release. The loop above cannot notice such a copy -- it only reads
# the documents it was given -- which is exactly how the count reached four.
#
# Two kinds of document legitimately carry a declaration that is not the live
# one, and neither is a copy to maintain:
#
#   * a shipped release directory, an immutable artifact that records the
#     contract current when it was published; and
#   * a root-level working document, which quotes the markers while describing
#     them and is deleted before release source finalization.
_release_reject_extra_current_blocks() {
	[ "$#" -eq 2 ] || return 2
	local repo_root=$1 designated=$2
	local document label find_pid
	local -a extra=()

	while IFS= read -r -d '' document; do
		label=${document#$repo_root/}
		[ "$label" != "$designated" ] || continue
		grep -Fq '<!-- current-release:start -->' "$document" || continue
		if _release_is_branch_only_document "$document" "$label"; then
			continue
		fi
		extra+=("$label")
	done < <(find "$repo_root" \
		\( -name .git -o -path "$repo_root/release/v[0-9]*" \) -prune -o \
		-type f \( -name '*.md' -o -name '*.adoc' \) -print0)
	find_pid=$!
	# A failed scan is a policy failure, not an empty result set.
	wait "$find_pid" \
		|| _release_documentation_error "could not scan for duplicate current-release declarations" || return
	[ "${#extra[@]}" -eq 0 ] \
		|| _release_documentation_error "the current release contract is declared in $designated alone; remove the bounded current-release block from: ${extra[*]}" || return
}

# Hold the LIVE tree to its own declaration, continuously.
#
# release_validate_current_documentation is a release-time check: make-release.sh
# supplies the version being cut and the canonical counts, and nothing calls it
# in between. So the single authority for the release contract -- the one bounded
# block that every other document was reduced to pointing at -- was verified only
# on release day. Between releases it could name any version, any counts, and any
# retained record, and the suite had no opinion.
#
# This is the same validator run against the working tree, with the two inputs
# taken from the two places that cannot be edited to agree with it: the version
# from the declaration itself, the image and soak counts from the Makefile that
# builds them. It then reconciles the declared version with what the tree can
# actually substantiate.
#
# The reconciliation is deliberately ONE-SIDED. A tree that declares a release
# whose retained record is absent must disclose that in the block a reader reads;
# a disclosure left standing after the cut is permitted, because the artifact
# commit may change only release/<version>/ and its exact publication-registry
# append, so it structurally cannot retract the disclosure. Refusing the stale
# direction too would put main red between the artifact commit and a retraction
# commit, which is a worse property than a disclosure that understates. The next
# source finalization rewrites the line for its own version, which is where a
# stale one is caught.
release_validate_development_state() {
	[ "$#" -eq 3 ] || return 2
	local repo_root=$1 image_count=$2 soak_count=$3
	local designated=release/README.md
	local document="$repo_root/$designated"
	local block plain version version_count transition_line retained_record

	[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
		|| _release_documentation_error "designated current-release document is not a regular nonempty file: $designated" || return
	block=$(_release_current_block "$document") \
		|| _release_documentation_error "$designated must contain one bounded current-release block" || return
	# release/README.md carries its block as a blockquote; the declaration is the
	# line, not its rendering.
	plain=$(awk '{ sub(/^>[[:space:]]*/, ""); print }' <<<"$block") || return

	version=$(sed -n 's/^\*\*Current release contract:\*\* `\(v[0-9][^`]*\)`;.*/\1/p' <<<"$plain") || return
	version_count=$(grep -c . <<<"$version" || true)
	[ "$version_count" -eq 1 ] \
		|| _release_documentation_error "$designated must declare exactly one current release contract version; found $version_count" || return
	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "$designated declares a version that is not vX.Y.Z: $version" || return

	# The counts come from the Makefile, so the exact-contract-line check inside
	# this call compares the declaration with the build rather than with itself.
	release_validate_current_documentation "$repo_root" "$version" \
		"$image_count" "$soak_count" || return

	# QUALIFICATION, not the directory, is what verify-release-history.sh treats
	# as "this tree already contains the release" -- so a half-staged directory
	# left by an aborted cut is still the pre-tag state and still owes the
	# disclosure. Use the verifier's minimum retained-record boundary: an empty
	# file or symlink is not release evidence merely because -f follows it.
	retained_record="$repo_root/release/$version/QUALIFICATION"
	if [ ! -f "$retained_record" ] || [ ! -s "$retained_record" ] \
			|| [ -L "$retained_record" ]; then
		transition_line=$(_release_transition_line "$version")
		[ "$(grep -Fxc "$transition_line" <<<"$plain" || true)" -eq 1 ] \
			|| _release_documentation_error "$designated declares $version, whose retained record release/$version/ this tree does not contain, and must carry the exact pre-tag transition line: $transition_line" || return
	fi
}

# Bind the bounded current-release declarations to the inventory that was
# actually STAGED, not to the canonical Makefile set that predicted it.
# release_validate_current_documentation runs before any build, so the strongest
# statement it can make is that the designated current documents agree with what
# the Makefile says a release will contain. This one runs on the staged
# directory and closes the loop a human would otherwise close by eye:
# "21 images; 18 soak combinations" in those documents against 21 files and 18
# soak records on disk. It is the last documentation check before the artifact
# commit and the tag.
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

# A branch-only working document is recognized by the declaration it carries,
# not by its name. Every name pattern this project has used was added after a
# document the previous pattern could not see had already been written:
# `v*-polish.md`, then `pre-v*-fixes.md`, then a third name matching neither.
# The next one will not match any of them either. The banner, by contrast, is
# written by whoever creates the document, in the words its human readers are
# already shown:
#
#   > **Branch-only working document.** ...
#
# Required in the opening blockquote (the first 20 lines) of a ROOT-LEVEL
# Markdown file, on both counts deliberately: a durable document that DESCRIBES
# the convention -- CHANGELOG.md and test/README.md both do, far below any
# banner -- is not a document making the declaration, and a working journal kept
# under docs/ is durable prose that ships until it is deleted.
#
# Classification never decides acceptance. A root-level Markdown document
# outside the durable set is refused by the release gate either way; the
# declaration only selects which diagnostic refuses it, and whether the
# live-tree documentation sweeps read the document as durable prose. A working
# document that omits its banner therefore fails closed, as allowlist drift,
# with the corrective action named -- as does one this helper cannot read.
_release_is_branch_only_document() {
	[ "$#" -eq 2 ] || return 2
	local document=$1 label=$2 opening
	case "$label" in
		*/*) return 1 ;;
		*.md) ;;
		*) return 1 ;;
	esac
	# Read into a variable rather than piping `head` into `grep`: every caller
	# runs under `pipefail`, where `grep -q` exiting on the first match can leave
	# the pipeline reporting `head`'s SIGPIPE and turn a declared document into
	# an undeclared one. An unreadable document stays undeclared, which is the
	# fail-closed side.
	opening=$(head -n 20 -- "$document" 2>/dev/null) || return 1
	grep -Eqi '^>[[:space:]]*\*\*Branch-(only|scoped)[[:space:]]+working[[:space:]]+document\.\*\*' \
		<<<"$opening"
}

# Reject a release cut from a tree that still contains -- or still references --
# a branch-only working document. Two kinds must fail, for different reasons:
#
#   * A DECLARED branch-only working document (see the helper above). Such a
#     document exists ONLY on a branch and must be deleted, and de-referenced,
#     in the final pre-merge commit; a production release is cut from main, so
#     none may remain.
#   * ANY other root-level Markdown document outside the durable set below.
#     Adding one name pattern per working document is precisely how this gate
#     came to miss `pre-v*-fixes.md`, so the root document set is an allowlist
#     rather than a blocklist: the durable documents ship, and any other
#     root-level document fails the release until it is deleted -- or added to
#     the set here, deliberately, because it now ships too.
#
# The reference half necessarily stays name-pattern based: once a document is
# deleted, its name is the only thing left to search for, so the two name
# families that have existed are listed there literally. A durable reference to
# a working document named outside them therefore dangles unseen once that
# document is gone; the presence half above is what keeps the document itself
# from ever reaching a release.
#
# Deliberately SEPARATE from release_validate_current_documentation: that
# validator runs in `--preflight`, which exercises the live checked-in tree
# (where a working document legitimately still exists during branch work). This
# gate is invoked only on the actual release-staging path, after preflight has
# exited, so it fails a real release closed without breaking the preflight
# capability probe.
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
		durable=0
		for durable_doc in "${durable_root_docs[@]}"; do
			if [ "$label" = "$durable_doc" ]; then
				durable=1
				break
			fi
		done
		# The durable set is consulted first, so a shipping document cannot be
		# talked out of the release by prose inside it.
		if [ "$durable" -eq 1 ]; then
			continue
		elif _release_is_branch_only_document "$root_doc" "$label"; then
			present_branch_docs+=("$label")
		else
			undeclared_root_docs+=("$label")
		fi
	done < <(find "$repo_root" -maxdepth 1 -type f -name '*.md' -print0)
	find_pid=$!
	wait "$find_pid" \
		|| _release_documentation_error "could not scan for branch-only working documents" || return
	[ "${#present_branch_docs[@]}" -eq 0 ] \
		|| _release_documentation_error "branch-only working document(s) must be deleted before release: ${present_branch_docs[*]}" || return
	[ "${#undeclared_root_docs[@]}" -eq 0 ] \
		|| _release_documentation_error "root-level document(s) outside the durable root-document set must be deleted before release, added to that set in release-documentation.sh if they now ship, or given the branch-only working-document banner if they are branch notes: ${undeclared_root_docs[*]}" || return

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
		if _release_is_branch_only_document "$document" "$label"; then
			continue
		fi
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
# Simplification must not strengthen a claim.
#
# This branch deleted ten design documents and consolidated what they said into
# five surviving authorities. Every one of those documents carried bounded
# claims -- statements of what the project does NOT know -- and a bound is the
# part of a sentence that a consolidation drops most easily, because dropping it
# leaves prose that still reads correctly and asserts more.
#
# The hardware/field-use split already has its own validator above, and the
# PIC12F675 raw-write and helper-status boundaries have theirs below. This one
# covers the boundaries that were left standing in prose alone, where an audit
# found that deleting them changed no test result:
#
#   * The ROOT README's qualification denial. HARDWARE_VALIDATION_LOG.md is
#     required to carry the sentinel, but README.md is where a reader arrives,
#     and nothing required README.md to agree with it. Replacing its denial with
#     "the release pipeline qualifies every image before publication" left the
#     complete suite green.
#   * PIC10F320's two recorded omissions. The general output-latch match is not
#     ported, and the equivalence argument is not a byte-identity claim. Both
#     are stated in DESIGN_DOCUMENTATION.adoc under headings that exist to state
#     them; deleting both paragraphs left the complete suite green.
#   * What reproducing the images proves, and what retaining an unsafe image
#     means. `release/README.md` bounds the first to "exactly what the tested
#     source compiles to" and the second to "historical integrity and
#     reproducibility" -- the two sentences that keep reproducibility from being
#     read as qualification, and retention from being read as endorsement.
#
# Three directions, because a bound can be lost by deletion, overwritten by a
# stronger claim, or weakened by making a live specification own a changing
# inventory or source-dependent result:
#
#   1. PRESENCE. Each bounded claim is required verbatim of the document that
#      owns it, matched against flowed text so rewrapping stays editorial.
#   2. ABSENCE. No durable document attributes controlled qualification or
#      hardware validation TO the firmware, an image, a part or a release --
#      "hardware-validated firmware" and its family -- while the sentinel says
#      no such record exists. The ban is deliberately attributive only. A
#      predicate can be negated, and every true sentence this project writes
#      about qualification IS the negation ("it is not hardware-qualified",
#      "has **not** completed controlled hardware qualification"), so banning
#      the predicate in both polarities would ban the truth along with the
#      claim. The adjective-plus-noun form has no negated spelling, which is
#      what makes it decidable. It is a floor, not a proof: prose can still
#      overclaim in words this does not enumerate.
#   3. CURRENT FACTS. DESIGN_DOCUMENTATION.adoc retains architecture, capacities,
#      reviewed ceilings and enforcing gates; TOOLCHAIN.adoc retains tool
#      requirements and behavior. Numeric release topology belongs only in the
#      bounded declaration in release/README.md, while current timing, size and
#      current-draw results belong to build output or source/toolchain-bound
#      release evidence. Focused lexical rules reject the concrete result and
#      inventory forms removed from those two live specifications.
#
# The ban is conditional on the sentinel, so it lifts by itself. When a part
# does complete controlled qualification the sentinel goes, and calling that
# part's image hardware-qualified becomes both true and sayable in the same
# commit that records the run.
#
# Scanned on the LIVE tree, like the hardware-claims contract it extends.
# Published release/vX.Y.Z/ directories are immutable artifacts and are pruned;
# so are the root-level branch-only working documents, which quote the banned
# wording in order to describe banning it.
release_validate_claim_boundaries() {
	[ "$#" -eq 1 ] || return 2
	local repo_root=$1
	local log="$repo_root/HARDWARE_VALIDATION_LOG.md"
	local sentinel='**No controlled hardware-qualification record exists for any part.**'
	local document label flowed entry required pattern description find_pid rc=0
	local -a claim_offenders=()
	# Adjective-plus-noun only; see the ABSENCE note above for why.
	local attributive_claim='hardware[-[:space:]](qualified|validated) (firmware|images?|binaries|parts?|releases?)'
	# "<document>|<sentence>". No bounded claim contains a pipe.
	local -a bounded_claims=(
		"README.md|**No part has completed controlled hardware qualification** — a bench run against a written procedure whose source/image identity, configuration bytes, instrument readings and acceptance result are retained."
		"DESIGN_DOCUMENTATION.adoc|the general output-**latch** match was not, because in every formulation that preserves its meaning it overruns 256 words on two of the three variants."
		"DESIGN_DOCUMENTATION.adoc|The general output-latch check is absent, as above."
		"DESIGN_DOCUMENTATION.adoc|The seam remains a seam: everything above is a behavioural assurance argument, and however thorough it is, it is a different kind of statement from \"the verified code is the shipped code\"."
		"DESIGN_DOCUMENTATION.adoc|Measured 2026-06-26 at source commit \`0b44c0d\` with free-tier XC8 V3.10 and PIC10-12Fxxx DFP V1.9.189"
		"release/README.md|That check is the public attestation that *these binaries are exactly what the tested source compiles to*"
		"release/README.md|These images are retained only for historical integrity and reproducibility."
	)
	# <document><TAB><extended regex><TAB><diagnostic>. Tabs keep regex
	# alternation available without inventing an escaping convention.
	local -a current_fact_rules=(
		$'DESIGN_DOCUMENTATION.adoc\t([0-9]+|one|two|three|four|five|six|seven|eight|nine)[[:space:]]+(MCU[[:space:]]+)?release[[:space:]]+(targets|parts)\trestates current release topology outside release/README.md'
		$'DESIGN_DOCUMENTATION.adoc\t([0-9]+|one|two|three|four|five|six|seven|eight|nine)[[:space:]]+targets[[:space:]]+use[[:space:]]+the[[:space:]]+modular[[:space:]]+architecture|all[[:space:]]+[0-9]+[[:space:]]+images|([0-9]+|one|two|three|four|five|six|seven|eight|nine)[[:space:]]+shell[[:space:]]+source[[:space:]]+files\trestates current release topology outside release/README.md'
		$'TOOLCHAIN.adoc\t([0-9]+|one|two|three|four|five|six|seven|eight|nine)-part,[[:space:]]*[0-9]+-image,[[:space:]]*[0-9]+-soak-combination[[:space:]]+product[[:space:]]+set|build(s|ing)?[[:space:]]+(its[[:space:]]+)?([0-9]+|one|two|three|four|five|six|seven|eight|nine)[[:space:]]+images[[:space:]]+into[[:space:]]+the[[:space:]]+published[[:space:]]+product[[:space:]]+set\trestates current release topology outside release/README.md'
		$'DESIGN_DOCUMENTATION.adoc\tMeasured[[:space:]]+worst[[:space:]]+pet-to-pet[[:space:]]+interval|per-tick[[:space:]]+sanity[[:space:]]+work[[:space:]]+is[[:space:]]+only.*instruction[[:space:]]+cycles|active[[:space:]]+IDD.*per-tick[[:space:]]+headroom\tcarries an unbound source-dependent measurement'
		$'TOOLCHAIN.adoc\tMeasured[[:space:]]+on[[:space:]]+one[[:space:]]+source.*-O0\tcarries an unbound source-dependent measurement'
	)

	for entry in "${bounded_claims[@]}"; do
		label=${entry%%|*}
		required=${entry#*|}
		document="$repo_root/$label"
		[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
			|| { _release_documentation_error "document owning a bounded claim is not a regular nonempty file: $label" || rc=1; continue; }
		flowed=$(_release_flowed_text "$document") || return
		case "$flowed" in
			*"$required"*) ;;
			*) _release_documentation_error "$label no longer states its bounded claim: $required" || rc=1 ;;
		esac
	done

	for entry in "${current_fact_rules[@]}"; do
		IFS=$'\t' read -r label pattern description <<<"$entry"
		document="$repo_root/$label"
		[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
			|| { _release_documentation_error "current-fact document is not a regular nonempty file: $label" || rc=1; continue; }
		flowed=$(_release_flowed_text "$document") || return
		if grep -Eiq -- "$pattern" <<<"$flowed"; then
			_release_documentation_error "$label $description" || rc=1
		fi
	done

	[ -f "$log" ] && [ -s "$log" ] && [ ! -L "$log" ] \
		|| _release_documentation_error "HARDWARE_VALIDATION_LOG.md is not a regular nonempty file" || return

	# No sentinel means a controlled record now exists, and the attributive
	# claim it licenses is somebody's to make. The presence rules above still
	# apply; only this ban lifts.
	if ! grep -Fq -- "$sentinel" "$log"; then
		return "$rc"
	fi

	while IFS= read -r -d '' document; do
		label=${document#$repo_root/}
		if _release_is_branch_only_document "$document" "$label"; then
			continue
		fi
		# Flowed BEFORE matching, not line by line: the form this bans is two
		# words, and a wrapped document splits it across the line break that a
		# line-oriented grep would then read as two innocent lines. Code and
		# quoted spans are blanked first, so naming the banned wording in order
		# to retire it stays possible -- the same NAMING-is-not-USING rule the
		# hardware-claims scan above applies to its own idiom.
		flowed=$(_release_unquoted_prose "$document" | tr '\n\t' '  ' | tr -s ' ') \
			|| { _release_documentation_error "could not read durable document: $label" || rc=1; continue; }
		if grep -Eqi -- "$attributive_claim" <<<"$flowed"; then
			claim_offenders+=("$label")
		fi
	done < <(find "$repo_root" \
		\( -name .git -o -path "$repo_root/release/v[0-9]*" \) -prune -o \
		-type f \( -name '*.md' -o -name '*.adoc' -o -name 'Makefile' \) -print0)
	find_pid=$!
	# A failed scan is a policy failure, not an empty result set.
	wait "$find_pid" \
		|| _release_documentation_error "could not scan durable documentation for attributed qualification claims" || return

	[ "${#claim_offenders[@]}" -eq 0 ] \
		|| _release_documentation_error "durable file(s) attribute controlled qualification or hardware validation to the firmware while HARDWARE_VALIDATION_LOG.md says no such record exists: ${claim_offenders[*]}" || rc=1

	return "$rc"
}

# release/README.md is the one maintained semantic owner of the source-checkout
# transaction, and every PUBLISHED PIC12F675 finalization command must carry the
# complete identity of the transaction it recovers.
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
# release/README.md is named because it is the sole live home of the guarded
# source-checkout transaction, so deleting the recovery example from it must
# fail. Every other document is DISCOVERED, and discovery keys on either half of
# the pair: a document that publishes a PROGRAMMING command is scanned exactly
# like one that publishes a recovery, so dropping the recovery while keeping the
# command it recovers cannot escape by no longer matching the search. A document
# that publishes NEITHER is not a publisher at all -- which is how README.md now
# points at the two routes without restating either. Shipped release directories
# (release/vX.Y.Z/) are excluded: they are immutable artifacts of past releases,
# and release/v0.9.9/MANIFEST.md legitimately publishes the older unsigned
# pic12f675-program transaction.
release_validate_pic12f675_finalization() {
	[ "$#" -eq 2 ] || return 2
	local repo_root=$1 version=$2
	local document label rendered toolchain find_pid rc=0
	# Always scanned, so deleting the recovery example from it is a failure with
	# a precise diagnostic rather than a silently empty scan.
	local -a publishers=("release/README.md")

	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "requested version is not vX.Y.Z: $version" || return

	# TOOLCHAIN.adoc owns installation, pinning and tool behavior. It links to
	# the operator transaction rather than maintaining the transaction's goals,
	# evidence paths, reservation files or temporary-storage policy a second time.
	toolchain="$repo_root/TOOLCHAIN.adoc"
	[ -f "$toolchain" ] && [ -s "$toolchain" ] && [ ! -L "$toolchain" ] \
		|| _release_documentation_error "PIC12F675 toolchain document is not a regular nonempty file: TOOLCHAIN.adoc" || return
	grep -Fq 'link:release/README.md#flash-a-chip[' "$toolchain" \
		|| _release_documentation_error "TOOLCHAIN.adoc does not link to release/README.md as the PIC12F675 source-checkout transaction owner" || rc=1
	if grep -Eq 'pic12f675-preflight|PIC12F675_(TRIM_EVIDENCE|BENCH_RESULT)|reservation\.json|result\.json|XDG_RUNTIME_DIR' \
			"$toolchain"; then
		_release_documentation_error "TOOLCHAIN.adoc restates PIC12F675 source-checkout transaction details owned by release/README.md" || rc=1
	fi

	while IFS= read -r -d '' document; do
		label=${document#$repo_root/}
		case "$label" in
			release/README.md) continue ;;
		esac
		# Root-level working documents quote the defective form of a command
		# while describing the defect; they are deleted before release.
		if _release_is_branch_only_document "$document" "$label"; then
			continue
		fi
		# A published command, not a prose mention. This finds a NEW document the
		# day it is written; the document named above is scanned either way, so a
		# command this pattern cannot see still fails inside the scan.
		grep -Eq '^[[:space:]]*make([[:space:]].*)?[[:space:]](pic12f675-finalize|pic12f675-program|pic12f675-release-program)([[:space:]]|\\|$)' \
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
	# The one sentence that resolves the contradiction B6 found, required
	# verbatim of every document that presents the helper's procedure.
	#
	# The selected policy is "helper published now, software-tested, not
	# hardware-qualified", and each half of it was being dropped somewhere.
	# FLASHING.md published the ipecmd procedure while README.md and
	# TOOLCHAIN.adoc said no ipecmd procedure was published at all -- a reader
	# who believed either one was misled about the other. This states both
	# halves in one sentence so a document cannot carry half of it.
	local helper_status='The helper'"'"'s `ipecmd` route is published and software-tested, but it is not hardware-qualified.'
	# The blanket denial the sentence above replaces. It is banned as a form
	# family rather than as three exact sentences, because the same false claim
	# survives an editor'"'"'s rewrap and an adjective swap; what it deliberately
	# does NOT ban is a claim SCOPED to a route ("this route offers no operator
	# ipecmd procedure"), which is true of the Make-based development and
	# release-provenance goals and must stay sayable.
	local unscoped_ipecmd_denial='no ipecmd( (hardware|user|write|operator|programming))? procedure is published'
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
		case "$flowed" in
			*"$helper_status"*) ;;
			*) _release_documentation_error "$label presents the PIC12F675 flashing helper without the exact published/software-tested/not-hardware-qualified status: $helper_status" || rc=1 ;;
		esac
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
	#    by pattern. A document may legitimately record its own retired
	#    position IN THE PAST TENSE ("The position was that no no-compiler
	#    path ... had been designed"), and a pattern wide enough to catch the
	#    live claim would fail on the record of how it was retired.
	#    Matched case-insensitively, and so spelled in lower case here: the same
	#    sentence at the start of a sentence is the same claim.
	local -a retired_state=(
		'there is not yet a no-compiler path'
		'the one place where a qualified direct-from-download path is not available today'
		'requires a clean source checkout of the same release tag and the pinned xc8/dfp toolchain'
	)
	while IFS= read -r -d '' document; do
		label=${document#$repo_root/}
		if _release_is_branch_only_document "$document" "$label"; then
			continue
		fi
		flowed=$(_release_flowed_text "$document") || return
		for retired in "${retired_state[@]}"; do
			case "${flowed,,}" in
				*"$retired"*)
					_release_documentation_error "$label still publishes the superseded PIC12F675 state, which the helper retired: $retired" || rc=1 ;;
			esac
		done
		# The blanket denial, scanned over EVERY current document rather than
		# the three publishers: it was TOOLCHAIN.adoc -- which publishes no
		# procedure of its own -- that carried one of the three offending
		# sentences, and the next one will be written somewhere else again.
		#
		# Backtick CHARACTERS are removed rather than their spans blanked,
		# which is the opposite of the hardware-claims sweep and deliberate:
		# every document here writes the tool as `ipecmd`, so blanking the span
		# would delete the one word the pattern turns on and let the natural
		# spelling of the denial straight through. Naming this form in order to
		# forbid it is therefore done by describing it, not by quoting it --
		# test/README.md says a document may not "deny that any ipecmd
		# procedure has been published", which is not the form itself.
		if grep -Eqi -- "$unscoped_ipecmd_denial" <<<"${flowed//\`/}"; then
			_release_documentation_error "$label denies that any ipecmd procedure is published; the release helper publishes one, so scope the claim to the Make route or say that route is not QUALIFIED" || rc=1
		fi
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
	case "$(printf '%s' "$rendered" | tr '\n\t' '  ' | tr -s ' ')" in
		*"$helper_status"*) ;;
		*) _release_documentation_error "generated release documentation does not carry the exact helper status: $helper_status" || rc=1 ;;
	esac
	if grep -Eqi -- "$unscoped_ipecmd_denial" <<<"${rendered//\`/}"; then
		_release_documentation_error "generated release documentation denies that any ipecmd procedure is published" || rc=1
	fi
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
	# "modeled-pin", not "physical": every lane this line names runs in a
	# simulator (yasimavr for AVR-XT, gpsim for the three PIC parts) and
	# observes MODELED package pins. The distinction matters more here than in
	# any static document, because this string is signed into MANIFEST.md and
	# published verbatim as the GitHub Release body, where a reader has no
	# repository context to correct it against. The register semantics that
	# legitimately keep the word "physical" -- GPIO reading pins rather than a
	# latch, PA2/PA3 versus PORTA.OUT -- are properties of the device, not
	# evidence claims, and none of them is stated here.
	printf ' (real-image fault handling, firmware/model ctx_ lock-step, and modeled-pin output checks across AVR-XT and all three PIC parts)'
	printf ' + %s-h parallel soak of every release soak combination (see evidence/).\n' "$hours"
	printf -- '- **`test-long` retention:** `evidence/test-long.summary.txt` retains one source-bound `TEST_LONG_RESULT` PASS record; the complete transcript is transient diagnostic output, is not a release asset, and is not required after verification. Tag CI reruns the gate independently, but its hosted job log is subject to platform retention and is not release evidence.\n'
}

# Render the MANIFEST toolchain table FROM the recorded evidence, so the human
# view and the machine record cannot be different lists. Reads the tab-separated
# records written by make-release.sh and emits one Markdown row each; the header
# rows are emitted here too so the whole table has one producer.
release_render_toolchain_table() {
	[ "$#" -eq 1 ] || return 2
	local artifact=$1 label version
	[ -f "$artifact" ] && [ ! -L "$artifact" ] && [ -s "$artifact" ] \
		|| _release_documentation_error \
			"toolchain evidence is missing, empty, or not a regular file: $artifact" \
		|| return 1
	printf -- '| tool | version |\n|---|---|\n'
	while IFS=$'\t' read -r label version; do
		case "$label" in
			TOOLCHAIN\ *|TOOLCHAIN_RESULT\ *) continue ;;
		esac
		[ -n "$label" ] && [ -n "$version" ] \
			|| _release_documentation_error \
				"malformed toolchain evidence record: $label" \
			|| return 1
		printf -- '| %s | %s |\n' "$label" "$version"
	done < "$artifact"
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
		'firmware development toolchain -- only Linux, Python 3 and MPLAB X 6.20' \
		'`ipecmd`. Linux is required because the helper hands the programmer its own' \
		'open descriptors instead of pathnames another process could re-point between' \
		'the last check and the write; elsewhere it refuses to touch a device.' \
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
		'device twice, reserves the write durably, writes exactly once, compares the' \
		'WHOLE device afterwards -- every word the image does not supply has to read' \
		'back erased -- and publishes one atomically installed, immutable PASS/FAIL' \
		'`result.json`. A PENDING directory -- a reservation with no' \
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
		'`1.x.y` bench pass, and the helper detects damage only after the write. The' \
		"helper's \`ipecmd\` route is published and software-tested, but it is not" \
		'hardware-qualified.' \
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

# Re-derive the source-checkout route here rather than trusting the producer's
# validation. The retained-manifest verifier has its own copy of the relation as
# a third opinion over the bytes that are eventually committed. Treat every
# other Make assignment as semantic, except the ATtiny202 route's required
# shell-safe UPDI path beneath /dev.
_release_source_command_valid() {
	[ "$#" -eq 2 ] || return 2
	local image=$1 command=$2 part variant expected_goal expected_selector word name
	local goal="" selector_name="" selector_value=""
	local goal_count=0 selector_count=0 extra_count=0 expected_extra_count=0
	local LC_ALL=C
	local -a words=()

	part=${image#*-}
	part=${part%%-*}
	variant=${image%.hex}
	variant=${variant##*-}
	case "$part" in
		attiny13a) expected_goal=attiny13a-program; expected_selector=VARIANT ;;
		attiny45)  expected_goal=attiny45-program;  expected_selector=VARIANT ;;
		attiny85)  expected_goal=attiny85-program;  expected_selector=VARIANT ;;
		attiny202) expected_goal=attiny202-program; expected_selector=VARIANT
			expected_extra_count=1 ;;
		pic10f322) expected_goal=pic10f322-program; expected_selector=VARIANT ;;
		pic10f320) expected_goal=pic10f320-program; expected_selector=PIC10F320_VARIANT ;;
		*) return 1 ;;
	esac

	read -r -a words <<<"$command"
	[ "${#words[@]}" -ge 3 ] && [ "${words[0]}" = make ] || return 1
	for word in "${words[@]:1}"; do
		case "$word" in
			*=*)
				name=${word%%=*}
				[[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
				if [ "$name" = "$expected_selector" ]; then
					selector_name=$name
					selector_value=${word#*=}
					selector_count=$((selector_count + 1))
				elif [ "$name" = XT_UPDI_PORT ] && [ "$part" = attiny202 ] \
						&& [[ "${word#*=}" =~ ^/dev/[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$ ]]; then
					extra_count=$((extra_count + 1))
				else
					return 1
				fi ;;
			*)
				goal=$word
				goal_count=$((goal_count + 1)) ;;
		esac
	done
	[ "$goal_count" -eq 1 ] && [ "$goal" = "$expected_goal" ] \
		&& [ "$selector_count" -eq 1 ] \
		&& [ "$selector_name" = "$expected_selector" ] \
		&& [ "$selector_value" = "$variant" ] \
		&& [ "$extra_count" -eq "$expected_extra_count" ]
}

release_render_flashing() {
	[ "$#" -eq 5 ] || return 2
	local flash_commands=$1 release_tag=$2
	local isp_programmer=$3 updi_programmer=$4 updi_port=$5
	local image profile command have_download=0
	[ -s "$flash_commands" ] && [ -f "$flash_commands" ] \
		&& [ ! -L "$flash_commands" ] || return 2
	[ -n "$isp_programmer" ] && [ -n "$updi_programmer" ] \
		&& [ -n "$updi_port" ] || return 2
	# The producer checks these rows in far more detail before calling. What is
	# refused here is what would make the RENDERED page wrong whoever produced
	# it: a part that must not carry a per-image command, a placeholder or a
	# fragment of prose that would land inside an executable block, and a
	# source-checkout invocation rendered as though a download could run it.
	while IFS=$'\t' read -r image profile command; do
		[ -n "$image" ] && [ -n "$profile" ] && [ -n "$command" ] || return 2
		case "$image" in
			*-pic12f675-*.hex) return 2 ;;
		esac
		case "$command" in
			*'<'*|*'>'*|*'(or:'*) return 2 ;;
		esac
		case "$profile" in
			make-source)
				_release_source_command_valid "$image" "$command" || return 2 ;;
			avrdude-isp|avrdude-updi|pk2cmd)
				case "$command" in
					*'make '*) return 2 ;;
					*"$image"*) have_download=1 ;;
					*) return 2 ;;
				esac ;;
			*) return 2 ;;
		esac
	done < "$flash_commands"
	[ "$have_download" -eq 1 ] || return 2

	printf '%s\n' \
		'## Flashing' \
		'' \
		'Every command in this section is complete. It names one released image,' \
		'carries the fuse or configuration bytes that image was qualified with, and' \
		'runs as written from the directory holding the download.' \
		'' \
		'AVR images need their fuse bytes in addition to the flash write (the Images' \
		'table above lists them per image, and the commands below carry the same' \
		'bytes). PIC images embed their configuration word in the HEX. PIC12F675 has' \
		'no per-image command at all: every write to that part goes through the' \
		'guarded transaction below -- pass its HEX to the `flash-pic12f675.py`' \
		'shipped in this release, never directly to a programmer.' \
		'' \
		'### Programmer profiles' \
		''
	printf '%s\n' \
		'The programmer and port in the commands below are this project'"'"'s defaults.' \
		'They are the only values here a reader may have to change, and changing one' \
		'is a substitution into an otherwise complete command.' \
		''
	printf '| images | interface | tool | this release publishes | if yours differs |\n'
	printf '|---|---|---|---|---|\n'
	printf '| ATtiny13a, ATtiny45, ATtiny85 | ISP | `avrdude` | `-c %s` | `avrdude -c ?` lists every programmer name your avrdude supports |\n' \
		"$isp_programmer"
	printf '| ATtiny202 | UPDI | `avrdude` | `-c %s -P %s` | your UPDI adapter'"'"'s device node; ISP programmers cannot drive UPDI |\n' \
		"$updi_programmer" "$updi_port"
	printf '| PIC10F320, PIC10F322 | ICSP | `pk2cmd` (PICkit 2) | an externally powered target | add `-T` to have the PICkit supply power |\n'
	printf '| PIC12F675 | ICSP | `flash-pic12f675.py` | the guarded transaction below | never a raw writer |\n'
	printf '\n'
	printf '%s\n' \
		'PICkit 3/4/5 program the PIC10F32x parts through MPLAB IPE'"'"'s `ipecmd` rather' \
		'than `pk2cmd`. Every command published here is pinned, byte for byte, to the' \
		'programming command this project'"'"'s Makefile defines by default, and that' \
		'default is `pk2cmd`. The `ipecmd` form is a non-default override of the same' \
		'goals and writes and verifies the same way, but its reset-release flag and' \
		'part-name spelling have not been confirmed against a part; that procedure' \
		'therefore stays in the source tree'"'"'s `FLASHING.md`, which carries the caveat' \
		'with it, rather than being published here as a complete command.' \
		'' \
		'### Per-image commands' \
		'' \
		'```sh'
	sort "$flash_commands" | while IFS=$'\t' read -r image profile command; do
		[ "$profile" = make-source ] && continue
		printf '# %s\n%s\n\n' "$image" "$command"
	done
	printf '```\n\n'
	if grep -q $'\tmake-source\t' "$flash_commands"; then
		printf '%s\n' \
			'### Source-checkout equivalents' \
			'' \
			'These need a checkout of this tag, not this download: the release bundle' \
			'ships no Makefile. They select the same image by its variant, and are' \
			'listed for provenance, not as an alternative for a reader who downloaded' \
			'the images.' \
			'' \
			'```sh'
		sort "$flash_commands" | while IFS=$'\t' read -r image profile command; do
			[ "$profile" = make-source ] || continue
			printf '# %s\n%s\n\n' "$image" "$command"
		done
		printf '```\n\n'
	fi
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
		express)
			# The soak hours are printed verbatim further down, from the same
			# $hours this line refers to, so the message cannot claim one
			# duration in prose and record another in its validation list.
			release_description='Prebuilt firmware images, express-qualified (every gate in full, shortened soak)'
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
