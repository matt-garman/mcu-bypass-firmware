#!/usr/bin/env bash
# Prove the committed release-artifact commit is publishable, then print the
# tag and push commands -- on success only.
#
# WHY THIS EXISTS
#   scripts/make-release.sh qualifies the SOURCE tree: it builds, gates and
#   soaks, then stages release/<version>/ and stops without touching Git. The
#   artifact commit is created by hand afterwards, so no gate in that run ever
#   sees the tree the tag will actually carry -- the one that CONTAINS
#   release/<version>/ and the publication-registry append.
#
#   That difference is not cosmetic. v0.9.12 passed every local gate, was
#   tagged and pushed, reproduced all 21 images bit for bit on the clean
#   runner, and then failed re-running the gates on the tag's tree: the
#   image-continuity row required a declaration that only becomes owed once
#   release/v0.9.12/ exists on disk. Locally it did not exist, so the gate was
#   green. The release was lost -- the tag is spent, the qualification is bound
#   to a source commit that must now change, and the 24-hour soak has to run
#   again. An earlier attempt died the same way on an unstaged toolchain.txt.
#
#   This script closes that window. It runs against HEAD, which by this point
#   IS the tree the tag will name, and it is the only place the tag and push
#   commands are printed. make-release.sh no longer prints them: an operator
#   who does not run this never receives a command to paste.
#
# WHY THIS GATE SET IS SUFFICIENT
#   verify-release-history.sh (run below, exactly as tag CI runs it) constrains
#   the artifact commit to release/<version>/ plus one canonical registry
#   append. A gate that reads neither cannot change its verdict between the
#   qualified source and this commit, so re-running the whole suite here would
#   buy nothing for the hours it costs. The gates that DO read them are named
#   by RELEASE_ARTIFACT_GATES in the Makefile, beside the rule for membership.
#
# THIS SCRIPT CHANGES NOTHING. Like make-release.sh, it commits, tags and
# pushes nothing; every Git operation below is a read.
set -euo pipefail
LC_ALL=C
export LC_ALL

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

ok() {
	printf 'ok: %s\n' "$*"
}

if [ "$#" -ne 1 ]; then
	printf 'usage: %s <version>\n' "$0" >&2
	exit 2
fi

VERSION=$1
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "invalid release version: $VERSION"

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) \
	|| die "cannot locate repository root"
cd "$REPO_ROOT" || die "cannot enter repository root: $REPO_ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	|| die "not inside a Git work tree: $REPO_ROOT"

# shellcheck source=release-signing-policy.sh
. "$REPO_ROOT/scripts/release-signing-policy.sh" \
	|| die "cannot read the release signing policy"

RELEASE_DIR="release/$VERSION"

# ----------------------------------------------------------------------------
# 1. The tree under test must be the tree the tag would name.
# ----------------------------------------------------------------------------
# A tag names a commit; every gate below reads the WORKING TREE. Where the two
# differ, this script would be qualifying something the tag does not carry --
# the entire failure it exists to prevent, one level closer in. An untracked
# file is that defect exactly as much as an uncommitted edit is, and it is the
# more likely one here: an evidence file left out of `git add` is present for
# the gates and absent from the release. Ignored files are not tree content and
# do not count.
dirty=$(git status --porcelain) || die "cannot read the working tree status"
[ -z "$dirty" ] || die "the working tree is not HEAD; commit, restore or remove these, then re-run:
$dirty
Every gate below reads the working tree, and the tag will carry the commit."
release_commit=$(git rev-parse HEAD) || die "cannot resolve HEAD"

# Re-tagging is not an amendment path. A tag that already exists here has
# either been pushed -- in which case the release is spent, and the next
# version is the way forward -- or it is a local leftover the operator must
# resolve deliberately rather than have this script silently bless.
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
	die "refs/tags/$VERSION already exists in this clone.
A published tag is not amended: cut the next version instead. If this tag was
never pushed, delete it deliberately before re-running."
fi

[ -d "$RELEASE_DIR" ] && [ ! -L "$RELEASE_DIR" ] \
	|| die "$RELEASE_DIR is missing or not a directory"
for required in QUALIFICATION SHA256SUMS SHA256SUMS.asc MANIFEST.md README.md; do
	[ -f "$RELEASE_DIR/$required" ] && [ ! -L "$RELEASE_DIR/$required" ] \
		&& [ -s "$RELEASE_DIR/$required" ] \
		|| die "$RELEASE_DIR/$required is missing, empty, or not a regular file"
done
if grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$RELEASE_DIR/MANIFEST.md"; then
	die "$RELEASE_DIR was produced by a dry run and must not be published"
fi
ok "HEAD is clean and $RELEASE_DIR carries the four files a release signs for itself."

# ----------------------------------------------------------------------------
# 2. The checks tag CI makes before it builds anything.
# ----------------------------------------------------------------------------
scripts/verify-release-signature.sh detached \
	"$RELEASE_DIR/SHA256SUMS.asc" "$RELEASE_DIR/SHA256SUMS" \
	|| die "the staged checksum signature does not verify against the pinned key"
ok "SHA256SUMS.asc verifies against $RELEASE_SIGNING_FINGERPRINT."

scripts/verify-release-history.sh "$RELEASE_DIR" "$VERSION" "$release_commit" \
	|| die "HEAD is not a publishable release-artifact commit"
ok "HEAD is a single-parent child of the qualified source and changes only $RELEASE_DIR/ plus the canonical registry append."

# ----------------------------------------------------------------------------
# 3. The gates whose verdict this commit can change.
# ----------------------------------------------------------------------------
# The pins come out of the release workflow rather than being restated here:
# they exist to be set independently of Make's production defaults so that a
# mismatch fails instead of agreeing with itself, and a second copy in this
# file would be one more thing to drift.
release_pins_text=$(
	python3 - "$REPO_ROOT/.github/workflows/release.yml" <<-'PY'
	import sys

	import yaml

	with open(sys.argv[1], encoding="utf-8") as handle:
	    workflow = yaml.safe_load(handle)
	env = workflow.get("env") or {}
	for name, value in sorted(env.items()):
	    if name.startswith("RELEASE_"):
	        print("%s=%s" % (name[len("RELEASE_"):], value))
	PY
) || die "cannot read the release workflow's independent pins (PyYAML absent?)"
[ -n "$release_pins_text" ] \
	|| die "the release workflow declares no RELEASE_* pins; refusing to run the gates unpinned"
mapfile -t release_pins <<<"$release_pins_text"

gates=$(make CC=: --no-print-directory print-RELEASE_ARTIFACT_GATES) \
	|| die "cannot read RELEASE_ARTIFACT_GATES from the Makefile"
[ -n "$gates" ] || die "RELEASE_ARTIFACT_GATES is empty"

printf '\nrunning the release-artifact gates on %s:\n  %s\n\n' \
	"${release_commit:0:12}" "$gates"
# STRICT_TOOLS=1 for the same reason CI sets it: a gate that skips because a
# tool is missing must fail this run, not pass it quietly.
# shellcheck disable=SC2086
make $gates STRICT_TOOLS=1 "${release_pins[@]}" \
	|| die "the release-artifact gates failed on HEAD.
This is the failure tag CI would have reported after the tag was pushed and
spent. Fix it on a NEW source commit, re-run the release, and tag that."
ok "every gate whose verdict this commit can change passed on HEAD."

# ----------------------------------------------------------------------------
# 4. Hand off -- the only place the tag and push commands are printed.
# ----------------------------------------------------------------------------
cat <<EOF

========== $VERSION is publishable -- tag and push (run by hand) ==========

  # 5. create a SIGNED, annotated tag on this exact commit ($(git rev-parse --short HEAD))
  git tag -s -u $RELEASE_SIGNING_FINGERPRINT $VERSION -m "Firmware release $VERSION"

  # 6. push the commit and the tag
  git push
  git push origin $VERSION

Ensure the remote protects v* tags from update and deletion. Tag CI rechecks
the remote target immediately before publication, but no workflow can make two
separate GitHub API operations atomic.

EOF
ok "nothing was committed, tagged, or pushed -- that is yours to do."
