#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# The release preparer writes the derived release lines, and writes only those.
#
# WHY THIS EXISTS. Cutting v0.9.12 took four commits to converge on seven lines,
# every one of which is a pure function of the version being cut, the version
# before it, and the release date: the heading form (twice -- the first attempt
# carried a `v` the heading does not take), the [Unreleased] section that has to
# survive the rename, both compare links, the bounded contract line, and the
# pre-tag transition line. The validator already parsed the previous version out
# of CHANGELOG.md in order to check a link it could have written; it refused
# instead, because refusing was the only verb it had for a durable document.
#
# So the property under test is not "the preparer produces plausible output". It
# is that the preparer produces THE OUTPUT THOSE FOUR COMMITS PRODUCED, byte for
# byte, from the tree that preceded them. That replay is the first case below and
# it is the one that would notice a format drift between the renderers and the
# documents a release actually ships.
#
# The rest hold the boundary. The preparer writes structure and derived strings;
# it never writes prose, never invents a release nobody described, and never
# walks the live declaration backwards onto a version already cut. And its own
# output must satisfy the validator that motivated it -- a preparer whose result
# the gate rejects has moved the hand edit one step later rather than removing
# it.
#
# NO TOOLCHAIN. Everything here is text: a Git fixture, two documents, and the
# renderers. It runs wherever Bash, Git and awk do.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PREPARE=$ROOT/scripts/release-prepare.sh
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

[ -f "$PREPARE" ] && [ -x "$PREPARE" ] \
	|| fail "scripts/release-prepare.sh is missing or not executable"

command -v git >/dev/null 2>&1 || fail "git is required"

work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-prepare.XXXXXX") \
	|| fail "could not create a work directory"
trap 'rm -rf "$work"' EXIT
output=$work/output

# ---------------------------------------------------------------------------
# Fixture. A minimal repository carrying the two documents the preparer edits,
# plus the scripts it sources. Minimal on purpose: the preparer's inputs are
# CHANGELOG.md, release/README.md and the Makefile's two canonical counts, and a
# fixture that copied the real tree would let an unrelated file decide a result.
# ---------------------------------------------------------------------------
repo=$work/repo

write_changelog() {
	local previous=${1:-0.9.11}
	cat > "$repo/CHANGELOG.md" <<EOF
# Changelog

## [Unreleased]

### Added

- A thing the maintainer decided to say about this release.

## [$previous] - 2026-08-29

### Fixed

- Something earlier.

## [0.9.10] - 2026-08-26

### Added

- Older still.

[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v$previous...HEAD
[$previous]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.10...v$previous
[0.9.10]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.9...v0.9.10
EOF
}

write_release_readme() {
	local version=${1:-v0.9.11}
	cat > "$repo/release/README.md" <<EOF
# Prebuilt firmware images

Prose a human wrote, which the preparer must not touch.

<!-- current-release:start -->
> **Current release contract:** \`$version\`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.
> The images cover three output stages; PIC10F320 is the self-contained target.
<!-- current-release:end -->

More prose below the block.
EOF
}

write_fixture() {
	rm -rf "$repo"
	mkdir -p "$repo/scripts" "$repo/release"
	cp "$ROOT/scripts/release-prepare.sh" "$repo/scripts/release-prepare.sh"
	cp "$ROOT/scripts/release-documentation.sh" "$repo/scripts/release-documentation.sh"
	chmod 0755 "$repo/scripts/release-prepare.sh"
	write_changelog "$@"
	write_release_readme
	git -C "$repo" init -q 2>/dev/null || fail "could not init the fixture repository"
	git -C "$repo" config user.email fixture@example.invalid
	git -C "$repo" config user.name Fixture
}

prepare() {
	( cd "$repo" && ./scripts/release-prepare.sh --images 21 --soaks 18 "$@" ) \
		>"$output" 2>&1
}

# ---------------------------------------------------------------------------
# 1. THE REPLAY. One command must reproduce what four hand commits produced.
#
# The pre-prep tree and the hand-made result both come out of this repository's
# own history, so this case measures the preparer against the release that was
# actually shipped rather than against a fixture written to agree with it. It is
# skipped only where that history is unavailable (a shallow clone, an exported
# archive), and never silently: the skip is reported.
# ---------------------------------------------------------------------------
replay_before=7a2d5c7^          # the tree before "change [Unreleased] to [0.9.12]"
replay_after=5c1d215            # "release: finalize v0.9.12 source contract"
replay_version=v0.9.12
replay_date=2026-09-03

if git -C "$ROOT" rev-parse -q --verify "$replay_before" >/dev/null 2>&1 \
		&& git -C "$ROOT" rev-parse -q --verify "$replay_after" >/dev/null 2>&1; then
	replay=$work/replay
	rm -rf "$replay"
	mkdir -p "$replay/scripts" "$replay/release"
	git -C "$ROOT" show "$replay_before:CHANGELOG.md" > "$replay/CHANGELOG.md" \
		|| fail "could not read the pre-prep CHANGELOG.md"
	git -C "$ROOT" show "$replay_before:release/README.md" > "$replay/release/README.md" \
		|| fail "could not read the pre-prep release/README.md"
	cp "$ROOT/scripts/release-prepare.sh" "$ROOT/scripts/release-documentation.sh" \
		"$replay/scripts/"
	chmod 0755 "$replay/scripts/release-prepare.sh"
	git -C "$replay" init -q 2>/dev/null || fail "could not init the replay repository"

	( cd "$replay" && ./scripts/release-prepare.sh \
		--images 21 --soaks 18 --date "$replay_date" "$replay_version" ) \
		>"$output" 2>&1 \
		|| fail "the preparer failed on the pre-v0.9.12 tree: $(<"$output")"

	git -C "$ROOT" show "$replay_after:CHANGELOG.md" > "$work/hand-CHANGELOG.md"
	git -C "$ROOT" show "$replay_after:release/README.md" > "$work/hand-release-README.md"

	cmp -s "$work/hand-CHANGELOG.md" "$replay/CHANGELOG.md" \
		|| fail "prepared CHANGELOG.md differs from the v0.9.12 release commit: $(diff -u "$work/hand-CHANGELOG.md" "$replay/CHANGELOG.md" | head -40)"
	pass
	cmp -s "$work/hand-release-README.md" "$replay/release/README.md" \
		|| fail "prepared release/README.md differs from the v0.9.12 release commit: $(diff -u "$work/hand-release-README.md" "$replay/release/README.md" | head -40)"
	pass
else
	printf 'note: v0.9.12 replay skipped -- %s or %s is unavailable in this clone\n' \
		"$replay_before" "$replay_after" >&2
fi

# ---------------------------------------------------------------------------
# 2. The seven derived lines, on the fixture.
# ---------------------------------------------------------------------------
write_fixture
prepare v0.9.12 --date 2026-09-03 \
	|| fail "the preparer rejected a well-formed fixture: $(<"$output")"

expect_line() {
	local file=$1 line=$2 description=$3
	grep -Fxq -- "$line" "$repo/$file" \
		|| fail "$description is missing from $file: $line"
	pass
}

expect_line CHANGELOG.md '## [0.9.12] - 2026-09-03' 'the dated release heading'
expect_line CHANGELOG.md '## [Unreleased]' 'the re-opened Unreleased section'
expect_line CHANGELOG.md \
	'[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.12...HEAD' \
	'the re-based Unreleased compare link'
expect_line CHANGELOG.md \
	'[0.9.12]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.11...v0.9.12' \
	'the frozen release compare link'
expect_line release/README.md \
	'> **Current release contract:** `v0.9.12`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.' \
	'the bounded contract line'
grep -Fq 'Pre-tag transition:' "$repo/release/README.md" \
	|| fail "the pre-tag transition line was not written"
pass

# The heading takes no `v`, and the wrong form is the first thing a hand edit
# produced. Pin both spellings so a renderer that confuses them fails here.
grep -Fxq '## [v0.9.12]' "$repo/CHANGELOG.md" \
	&& fail "the release heading carries a 'v' the format does not take"
pass

# Exactly one Unreleased heading survives. Two would mean the rename duplicated
# rather than moved, which no later gate distinguishes from correct output.
[ "$(grep -Fxc '## [Unreleased]' "$repo/CHANGELOG.md")" -eq 1 ] \
	|| fail "the prepared CHANGELOG.md does not carry exactly one Unreleased heading"
pass

# The prepared section is the one the maintainer wrote, still under its heading.
awk '
	$0 == "## [0.9.12] - 2026-09-03" { in_section=1; next }
	in_section && /^## \[/ { exit }
	in_section && /^- A thing the maintainer decided to say/ { found=1 }
	END { exit !found }
' "$repo/CHANGELOG.md" \
	|| fail "the maintainer's entries did not stay under the dated heading"
pass

# Prose outside the bounded block is untouched.
for prose in 'Prose a human wrote, which the preparer must not touch.' \
		'More prose below the block.' \
		'> The images cover three output stages; PIC10F320 is the self-contained target.'; do
	grep -Fxq -- "$prose" "$repo/release/README.md" \
		|| fail "the preparer altered prose it does not own: $prose"
	pass
done

# ---------------------------------------------------------------------------
# 3. Idempotence, and the date it must not move.
# ---------------------------------------------------------------------------
cp "$repo/CHANGELOG.md" "$work/first-CHANGELOG.md"
cp "$repo/release/README.md" "$work/first-release-README.md"
prepare v0.9.12 || fail "the second run failed: $(<"$output")"
cmp -s "$work/first-CHANGELOG.md" "$repo/CHANGELOG.md" \
	|| fail "a second run changed CHANGELOG.md"
pass
cmp -s "$work/first-release-README.md" "$repo/release/README.md" \
	|| fail "a second run changed release/README.md"
pass
# Re-running WITHOUT --date must keep the date the first run wrote, not today's.
grep -Fxq '## [0.9.12] - 2026-09-03' "$repo/CHANGELOG.md" \
	|| fail "a second run moved the release date"
pass

# --check reports a prepared tree as current and writes nothing.
prepare v0.9.12 --check || fail "--check rejected a prepared tree: $(<"$output")"
pass

# ---------------------------------------------------------------------------
# 4. --check on a stale tree reports, exits nonzero, and writes nothing.
# ---------------------------------------------------------------------------
write_fixture
cp "$repo/CHANGELOG.md" "$work/stale-CHANGELOG.md"
cp "$repo/release/README.md" "$work/stale-release-README.md"
if prepare v0.9.12 --check; then
	fail "--check accepted an unprepared tree"
fi
pass
grep -Fq 'STALE' "$output" || fail "--check did not name the stale documents: $(<"$output")"
pass
cmp -s "$work/stale-CHANGELOG.md" "$repo/CHANGELOG.md" \
	|| fail "--check modified CHANGELOG.md"
pass
cmp -s "$work/stale-release-README.md" "$repo/release/README.md" \
	|| fail "--check modified release/README.md"
pass

# ---------------------------------------------------------------------------
# 5. Refusals. Each leaves both documents byte-identical: a preparer that
#    half-writes is worse than one that declines, because the partial result
#    reads as prepared.
# ---------------------------------------------------------------------------
assert_refused() {
	local description=$1 expected=$2
	shift 2
	cp "$repo/CHANGELOG.md" "$work/before-CHANGELOG.md"
	cp "$repo/release/README.md" "$work/before-release-README.md"
	if prepare "$@"; then
		fail "the preparer accepted $description"
	fi
	grep -Fq -- "$expected" "$output" \
		|| fail "$description was refused for the wrong reason: $(<"$output")"
	cmp -s "$work/before-CHANGELOG.md" "$repo/CHANGELOG.md" \
		|| fail "$description left CHANGELOG.md modified"
	cmp -s "$work/before-release-README.md" "$repo/release/README.md" \
		|| fail "$description left release/README.md modified"
	pass
}

write_fixture
assert_refused 'a version that is not vX.Y.Z' 'is not vX.Y.Z' 0.9.12
assert_refused 'no version at all' 'no <version> given'
assert_refused 'a non-numeric image count' 'image count is not a positive integer' \
	v0.9.12 --images seven

# An [Unreleased] section with no content is a release nobody described. The
# preparer will not manufacture a heading over it.
write_fixture
awk '
	$0 == "## [Unreleased]" { print; print ""; skip=1; next }
	skip && /^## \[/ { skip=0 }
	!skip
' "$repo/CHANGELOG.md" > "$work/empty.md" && cp "$work/empty.md" "$repo/CHANGELOG.md"
assert_refused 'an empty [Unreleased] section' \
	'has no category-plus-entry content' v0.9.12

# A section with a category but no entries, and entries but no category: both
# halves of the contract are load-bearing, so neither alone may pass.
write_fixture
awk '$0 == "- A thing the maintainer decided to say about this release." { next } { print }' \
	"$repo/CHANGELOG.md" > "$work/no-entries.md" \
	&& cp "$work/no-entries.md" "$repo/CHANGELOG.md"
assert_refused 'a category with no entries' \
	'has no category-plus-entry content' v0.9.12

write_fixture
awk '$0 == "### Added" && !done { done=1; next } { print }' \
	"$repo/CHANGELOG.md" > "$work/no-category.md" \
	&& cp "$work/no-category.md" "$repo/CHANGELOG.md"
assert_refused 'entries with no category' \
	'has no category-plus-entry content' v0.9.12

# Two [Unreleased] headings: the preparer cannot know which one to rename.
write_fixture
printf '\n## [Unreleased]\n' >> "$repo/CHANGELOG.md"
assert_refused 'a duplicated Unreleased heading' \
	'exactly one' v0.9.12

# No bounded block in release/README.md.
write_fixture
awk '!/current-release:(start|end)/' "$repo/release/README.md" > "$work/no-block.md" \
	&& cp "$work/no-block.md" "$repo/release/README.md"
assert_refused 'a release/README.md with no bounded block' \
	'bounded current-release block' v0.9.12

# ---------------------------------------------------------------------------
# 6. An already-cut version is refused, in both directions.
#
# This is the preparer's one destructive move: preparing a released version
# rewrites the live declaration BACKWARDS onto it, and every line it writes is
# individually well-formed, so nothing downstream would object.
# ---------------------------------------------------------------------------
write_fixture
mkdir -p "$repo/release/v0.9.12"
printf 'source_commit=0000000000000000000000000000000000000000\n' \
	> "$repo/release/v0.9.12/QUALIFICATION"
assert_refused 'a version whose retained record is already on disk' \
	'is already cut' v0.9.12

write_fixture
git -C "$repo" add -A >/dev/null 2>&1
git -C "$repo" commit -qm fixture >/dev/null 2>&1
git -C "$repo" tag v0.9.12 >/dev/null 2>&1
assert_refused 'a version that is already tagged' 'is already tagged' v0.9.12

# ---------------------------------------------------------------------------
# 7. The output satisfies the validator that motivated the preparer.
#
# Read directly rather than inferred from a successful run: the preparer calls
# this itself, so a broken call site could otherwise pass by never running.
# ---------------------------------------------------------------------------
write_fixture
prepare v0.9.13 --date 2026-10-01 \
	|| fail "the preparer failed on a fresh version: $(<"$output")"
pass

# shellcheck source=../scripts/release-documentation.sh
source "$ROOT/scripts/release-documentation.sh" \
	|| fail "could not source the release documentation helper"
release_validate_current_documentation "$repo" v0.9.13 21 18 >"$output" 2>&1 \
	|| fail "prepared documents fail the release documentation contract: $(<"$output")"
pass

# The counts are the caller's, so a declaration prepared for one inventory must
# not validate against another. This is what binds the document to the build.
if release_validate_current_documentation "$repo" v0.9.13 20 18 >"$output" 2>&1; then
	fail "the contract accepted a declaration written for a different image count"
fi
pass

printf 'release prepare: %d checks, 0 failures\n' "$checks"
