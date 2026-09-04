#!/usr/bin/env bash
#
# release-prepare.sh -- write the derived release lines into the working tree.
#
# WHY THIS EXISTS
#   Cutting a release used to require hand-editing seven lines across two
#   documents until scripts/release-documentation.sh stopped objecting.
#   Preparing v0.9.12 took four commits to converge on them:
#
#     ## [Unreleased]  ->  ## [v0.9.12]        (wrong: the heading carries no `v`)
#                      ->  ## [0.9.12] - DATE  (right, on the second try)
#     +## [Unreleased]                         (the empty section must survive)
#     the [Unreleased]: compare link, re-based on the version being cut
#     the [X.Y.Z]: compare link, previous tag to this one
#     the bounded contract line's version
#     the pre-tag transition line
#
#   Every one of those is a pure function of three inputs -- the version being
#   cut, the version before it, and the release date. None of them records a
#   decision anybody made. The release tooling already knew all three: the
#   validator parses the previous version out of CHANGELOG.md in order to check
#   a link it could have written. It refused instead, because for durable
#   documents refusing was the only verb it had.
#
#   This script is the missing verb. It renders those lines through the same
#   functions the validator compares against (release_render_* in
#   release-documentation.sh), so the writer and the checker cannot disagree
#   about the format, and a mismatch has exactly one repair: run this again.
#
# WHAT IT DOES NOT DO
#   It writes structure and derived strings. It never writes prose. The
#   [Unreleased] section's contents are the maintainer's, and this script
#   refuses to run if that section is empty -- a release with nothing said
#   about it is a mistake, not something to paper over with a heading.
#
#   It does not tag, commit, build, or stage anything. It edits two documents
#   in the working tree and leaves them for review. scripts/make-release.sh is
#   still what cuts a release, and it still validates these documents itself.
#
# USAGE
#   scripts/release-prepare.sh [options] <version>
#
#     --images N     canonical image count      (default: ask the Makefile)
#     --soaks N      canonical soak count       (default: ask the Makefile)
#     --date DATE    release date, YYYY-MM-DD   (default: today, UTC)
#     --check        report what would change; write nothing; exit 1 if stale
#     --help
#
# IDEMPOTENCE
#   Running it twice is safe. Once a dated section for the version exists, the
#   rename has already happened; a re-run re-asserts the links and the bounded
#   declaration and keeps the date the first run wrote.

set -euo pipefail

SELF=${0##*/}

# GNU Make exports command-line variables to recipes, so `make release-prepare
# VERSION=vX.Y.Z` arrives in the environment rather than as an argument. Capture
# it before the option parser assigns to VERSION, the same way make-release.sh
# does, so arbitrary bytes never reach the recipe's shell syntax; the semantic
# validation below then treats it exactly like a positional argument.
MAKE_VERSION=${VERSION-}

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

usage() { sed -n '/^# USAGE/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

VERSION=""
IMAGE_COUNT=""
SOAK_COUNT=""
RELEASE_DATE=""
CHECK_ONLY=0

while [ "$#" -gt 0 ]; do
	case "$1" in
		--images) [ "$#" -ge 2 ] || die "--images needs a value"; IMAGE_COUNT=$2; shift 2 ;;
		--soaks)  [ "$#" -ge 2 ] || die "--soaks needs a value";  SOAK_COUNT=$2;  shift 2 ;;
		--date)   [ "$#" -ge 2 ] || die "--date needs a value";   RELEASE_DATE=$2; shift 2 ;;
		--check)  CHECK_ONLY=1; shift ;;
		--help|-h) usage; exit 0 ;;
		--*) die "unknown option: $1. Try --help." ;;
		*) [ -z "$VERSION" ] || die "unexpected extra argument: $1"; VERSION=$1; shift ;;
	esac
done

if [ -z "$VERSION" ] && [ -n "$MAKE_VERSION" ]; then
	VERSION=$MAKE_VERSION
fi
[ -n "$VERSION" ] || die "no <version> given (e.g. v1.0.0). Try --help."
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "version '$VERSION' is not vX.Y.Z (optionally -suffix)"
RELEASE_NUMBER=${VERSION#v}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
	|| die "not inside a git repository"
cd "$REPO_ROOT" || die "could not enter $REPO_ROOT"

# Preparing a version that has already been cut would walk the live declaration
# BACKWARDS to a release whose record is on disk and whose tag is signed --
# quietly, because every line it writes is individually well-formed. The two
# independent signals that a cut has happened are the retained record and the
# tag; either one is enough to refuse. This is the one destructive direction
# the preparer has, so it is closed before anything is read.
RETAINED_RECORD=$REPO_ROOT/release/$VERSION/QUALIFICATION
if [ -f "$RETAINED_RECORD" ] && [ -s "$RETAINED_RECORD" ] && [ ! -L "$RETAINED_RECORD" ]; then
	die "$VERSION is already cut: release/$VERSION/QUALIFICATION is a retained record. Prepare the NEXT version instead"
fi
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
	die "$VERSION is already tagged. Prepare the NEXT version instead"
fi

CHANGELOG=$REPO_ROOT/CHANGELOG.md
RELEASE_README=$REPO_ROOT/release/README.md
for document in "$CHANGELOG" "$RELEASE_README"; do
	[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
		|| die "not a regular nonempty file: ${document#$REPO_ROOT/}"
done

# The renderers are the format authority. Sourcing them rather than repeating
# them is the whole point: the validator compares against these same functions.
# shellcheck source=release-documentation.sh
source "$REPO_ROOT/scripts/release-documentation.sh" \
	|| die "release documentation helper could not be loaded"
for renderer in release_render_contract_line release_render_changelog_heading \
		release_render_unreleased_link release_render_release_link \
		_release_transition_line _release_current_block \
		release_validate_current_documentation; do
	declare -F "$renderer" >/dev/null \
		|| die "release documentation helper does not define $renderer"
done

# The counts are the Makefile's, not this script's. Asking it keeps the
# declaration bound to the inventory that will actually be built, which is the
# property the validator's exact-contract-line check exists to establish.
ask_make() {
	local name=$1 value
	value=$(${PROJECT_MAKE:-make} -s "print-$name" 2>/dev/null) \
		|| die "could not query the Makefile for $name"
	printf '%s\n' "$value" | tr ' ' '\n' | grep -c . || true
}
[ -n "$IMAGE_COUNT" ] || IMAGE_COUNT=$(ask_make RELEASE_IMAGES)
[ -n "$SOAK_COUNT" ] || SOAK_COUNT=$(ask_make RELEASE_SOAK_NAMES)
[[ "$IMAGE_COUNT" =~ ^[1-9][0-9]*$ ]] || die "image count is not a positive integer: $IMAGE_COUNT"
[[ "$SOAK_COUNT" =~ ^[1-9][0-9]*$ ]] || die "soak count is not a positive integer: $SOAK_COUNT"

# ---------------------------------------------------------------------------
# CHANGELOG.md
# ---------------------------------------------------------------------------

# Is this version already dated? Then the rename has happened and the date is
# whatever the first run wrote; re-running must not move it.
EXISTING_HEADING=$(grep -E "^## \[${RELEASE_NUMBER//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" \
	"$CHANGELOG" || true)
ALREADY_DATED=0
if [ -n "$EXISTING_HEADING" ]; then
	[ "$(grep -c . <<<"$EXISTING_HEADING")" -eq 1 ] \
		|| die "CHANGELOG.md carries more than one dated [$RELEASE_NUMBER] section"
	ALREADY_DATED=1
	RELEASE_DATE=${EXISTING_HEADING##* - }
fi
if [ -z "$RELEASE_DATE" ]; then
	RELEASE_DATE=$(date -u +%Y-%m-%d) || die "could not determine today's date"
fi
[[ "$RELEASE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
	|| die "release date is not YYYY-MM-DD: $RELEASE_DATE"

UNRELEASED_COUNT=$(grep -Fxc '## [Unreleased]' "$CHANGELOG" || true)
[ "$UNRELEASED_COUNT" -eq 1 ] \
	|| die "CHANGELOG.md must carry exactly one '## [Unreleased]' heading; found $UNRELEASED_COUNT"

# The one thing here that is not derived: did the maintainer say anything about
# this release? A dated heading over an empty section is a release nobody
# described, and this script will not manufacture one.
if [ "$ALREADY_DATED" -eq 0 ]; then
	pending=$(awk '
		$0 == "## [Unreleased]" { in_section=1; next }
		in_section && /^## \[/ { exit }
		in_section && /^### (Added|Changed|Deprecated|Removed|Fixed|Security)$/ { categories++ }
		in_section && /^- / { entries++ }
		END { if (categories > 0 && entries > 0) print "ok" }
	' "$CHANGELOG") || die "could not scan CHANGELOG.md"
	[ "$pending" = "ok" ] \
		|| die "the [Unreleased] section has no category-plus-entry content; describe $VERSION before preparing it"
fi

# The previous release is the first dated section below the one being cut --
# before the rename that is the first section under [Unreleased], and after it
# the first one under the new dated heading. Reading it AFTER the rename would
# find the section this run just created.
PREVIOUS_VERSION=$(awk -v skip="## [$RELEASE_NUMBER] - $RELEASE_DATE" '
	$0 == "## [Unreleased]" { next }
	$0 == skip { next }
	/^## \[[^]]+\] - / {
		name=$0
		sub(/^## \[/, "", name)
		sub(/\] - .*/, "", name)
		print "v" name
		exit
	}
' "$CHANGELOG") || die "could not scan CHANGELOG.md for the preceding release"
[[ "$PREVIOUS_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "CHANGELOG.md has no preceding dated release section to compare against"
[ "$PREVIOUS_VERSION" != "$VERSION" ] \
	|| die "CHANGELOG.md already lists $VERSION as the preceding release"

HEADING_LINE=$(release_render_changelog_heading "$VERSION" "$RELEASE_DATE")
UNRELEASED_LINK=$(release_render_unreleased_link "$VERSION")
RELEASE_LINK=$(release_render_release_link "$VERSION" "$PREVIOUS_VERSION")
CONTRACT_LINE=$(release_render_contract_line "$VERSION" "$IMAGE_COUNT" "$SOAK_COUNT")
TRANSITION_LINE=$(_release_transition_line "$VERSION")

LINK_PREFIX_UNRELEASED='[Unreleased]: '
LINK_PREFIX_RELEASE="[$RELEASE_NUMBER]: "

changed=0
scratch=$(mktemp -d "${TMPDIR:-/tmp}/release-prepare.XXXXXX") \
	|| die "could not create a scratch directory"
trap 'rm -rf "$scratch"' EXIT

# Write $2 over $1 only if the bytes differ, preserving the original mode.
install_if_changed() {
	local target=$1 candidate=$2 label=${1#$REPO_ROOT/}
	if cmp -s "$target" "$candidate"; then
		note "  unchanged  $label"
		return 0
	fi
	changed=1
	if [ "$CHECK_ONLY" -eq 1 ]; then
		note "  STALE      $label"
		diff -u "$target" "$candidate" | sed -n '3,$p' | sed 's/^/    /' >&2 || true
		return 0
	fi
	cat "$candidate" > "$target" || die "could not write $label"
	note "  written    $label"
}

# 1. The heading rename, and the [Unreleased] section that must survive it.
#    Done as one awk pass so the two cannot get out of step: every path that
#    emits the dated heading emits a fresh empty [Unreleased] above it.
# 2. Both compare links. The moving one is rewritten in place; the frozen one
#    is inserted directly beneath it, which is where every previous release put
#    its own and keeps the list in descending order.
awk -v already="$ALREADY_DATED" \
	-v heading="$HEADING_LINE" \
	-v unreleased_link="$UNRELEASED_LINK" \
	-v release_link="$RELEASE_LINK" \
	-v release_prefix="$LINK_PREFIX_RELEASE" \
	-v unreleased_prefix="$LINK_PREFIX_UNRELEASED" '
	$0 == "## [Unreleased]" && !already {
		print "## [Unreleased]"
		print ""
		print heading
		next
	}
	index($0, unreleased_prefix) == 1 {
		print unreleased_link
		print release_link
		next
	}
	index($0, release_prefix) == 1 { next }
	{ print }
' "$CHANGELOG" > "$scratch/CHANGELOG.md" || die "could not rewrite CHANGELOG.md"

for required in "$HEADING_LINE" "$UNRELEASED_LINK" "$RELEASE_LINK" '## [Unreleased]'; do
	grep -Fxq "$required" "$scratch/CHANGELOG.md" \
		|| die "rewritten CHANGELOG.md is missing a line it must carry: $required"
done

# ---------------------------------------------------------------------------
# release/README.md -- the one bounded declaration
# ---------------------------------------------------------------------------
#
# The block is a blockquote, so each line carries a `> ` prefix that belongs to
# the rendering rather than to the declaration. The contract line is replaced
# in place. The transition line is APPENDED when the retained record is absent
# and left alone otherwise: the validator's reconciliation is deliberately
# one-sided, permitting a disclosure that outlives the cut, because the
# artifact commit structurally cannot retract it.

_release_current_block "$RELEASE_README" >/dev/null \
	|| die "release/README.md must contain one bounded current-release block"

# Always required here, and the already-cut guard at the top is what makes that
# true rather than an assumption: it refuses precisely the case -- a retained
# record present -- in which the disclosure would be wrong. Deriving it a second
# time would read as a condition that can vary, and it cannot.
need_transition=1

awk -v contract="$CONTRACT_LINE" \
	-v transition="$TRANSITION_LINE" \
	-v need_transition="$need_transition" '
	$0 == "<!-- current-release:start -->" { inside=1; print; next }
	$0 == "<!-- current-release:end -->" {
		if (inside && need_transition && !saw_transition) print "> " transition
		inside=0; print; next
	}
	inside {
		line=$0
		sub(/^>[[:space:]]*/, "", line)
		if (index(line, "**Current release contract:**") == 1) {
			print "> " contract
			next
		}
		if (index(line, "**Pre-tag transition:**") == 1) {
			saw_transition=1
			if (need_transition) { print "> " transition; next }
			print
			next
		}
		print
		next
	}
	{ print }
' "$RELEASE_README" > "$scratch/release-README.md" \
	|| die "could not rewrite release/README.md"

grep -Fq "$CONTRACT_LINE" "$scratch/release-README.md" \
	|| die "rewritten release/README.md does not carry the contract line for $VERSION"

# ---------------------------------------------------------------------------
# Install, only now that BOTH candidates exist and both are well formed.
#
# The two rewrites used to install as they were produced, so a fault discovered
# while rendering the second document left the first one already written --
# a tree that is half-prepared and reads as prepared. Every refusal above now
# happens before any target file is touched. This ordering is the property;
# test/test_release_prepare.sh asserts it for each refusal path, which is how
# the original defect was found.
# ---------------------------------------------------------------------------

install_if_changed "$CHANGELOG" "$scratch/CHANGELOG.md"
install_if_changed "$RELEASE_README" "$scratch/release-README.md"

# ---------------------------------------------------------------------------
# Prove the output satisfies the gate it was written for.
# ---------------------------------------------------------------------------
#
# A preparer whose output its own validator rejects is worse than no preparer:
# it moves the hand edit one step later and makes the diagnostic harder to
# read. So the check runs here, against the tree as it now stands, in the same
# production mode make-release.sh uses.

if [ "$CHECK_ONLY" -eq 1 ]; then
	[ "$changed" -eq 0 ] || exit 1
	note "$SELF: $VERSION is prepared and current"
	exit 0
fi

release_validate_current_documentation "$REPO_ROOT" "$VERSION" \
	"$IMAGE_COUNT" "$SOAK_COUNT" \
	|| die "documents were written but do not satisfy the release documentation contract; the diagnostics above are the defect"

if [ "$changed" -eq 0 ]; then
	note "$SELF: $VERSION was already prepared; nothing to change"
else
	note "$SELF: prepared $VERSION ($PREVIOUS_VERSION -> $VERSION, $RELEASE_DATE, $IMAGE_COUNT images, $SOAK_COUNT soaks)"
	note "$SELF: review the two documents, then commit them before running a release"
fi
