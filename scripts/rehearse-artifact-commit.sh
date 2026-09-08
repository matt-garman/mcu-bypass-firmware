#!/usr/bin/env bash
# Build the release-artifact commit SHAPE in a scratch clone and prove it, an
# hour into a dry run rather than a day into a real one.
#
# WHY THIS EXISTS
#   scripts/make-release.sh qualifies the source tree and stops. The tree a tag
#   actually names is the one that CONTAINS release/<version>/ and the
#   publication-registry append, and that tree does not exist until an operator
#   has committed by hand -- so no gate in a release run ever sees it.
#   scripts/verify-release-artifact-commit.sh closes that window, but only
#   AFTER the 24-hour soak has already been spent: it runs on the commit, and
#   the commit comes last.
#
#   v0.9.12 is what that costs. It passed every local gate, was tagged and
#   pushed, reproduced all 21 images bit for bit on the clean runner, and then
#   failed re-running the gates on the tag's tree, because the image-continuity
#   row required a declaration that only becomes owed once release/v0.9.12/
#   exists on disk. The tag was spent and the soak had to run again.
#
#   The staged SHAPE does not depend on soak duration; only the evidence
#   CONTENT does. So the whole failure class above is reachable from a dry run,
#   whose soak is minutes. This script is that rehearsal: it assembles the
#   artifact commit from a dry run's staging in a throwaway clone and runs the
#   real verifier against it.
#
# WHAT IT PROVES, AND WHAT IT DOES NOT
#   It proves the shape: a single-parent child of the qualified source changing
#   only release/<version>/ plus the canonical registry append, and every gate
#   whose verdict that commit can change passing on it. It does not prove the
#   evidence content -- a dry run's soak is deliberately short -- nor the
#   checksum signature, which does not exist until the operator signs the real
#   staging by hand.
#
# IT TOUCHES NOTHING IN THIS REPOSITORY. The clone is a throwaway under a
# caller-chosen scratch directory; every Git operation against the real
# repository is a read.
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

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	printf 'usage: %s <staged-release-dir> <version> [scratch-parent-dir]\n' "$0" >&2
	exit 2
fi

STAGED=$1
VERSION=$2
SCRATCH_PARENT=${3:-${TMPDIR:-/tmp}}

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "invalid release version: $VERSION"

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) \
	|| die "cannot locate repository root"
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	|| die "not inside a Git work tree: $REPO_ROOT"

[ -d "$STAGED" ] && [ ! -L "$STAGED" ] \
	|| die "staged release directory is missing or not a directory: $STAGED"
STAGED=$(cd "$STAGED" && pwd -P) || die "cannot resolve staged directory: $STAGED"

# A rehearsal rehearses a DRY RUN, and only a dry run. Pointed at a real
# staging it would assemble a commit that looks publishable and then be refused
# by the verifier for exactly that reason; refuse here instead, where the
# diagnostic can say which mode produces what.
[ -f "$STAGED/MANIFEST.md" ] \
	|| die "$STAGED/MANIFEST.md is missing: this is not a staged release directory"
grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE' "$STAGED/MANIFEST.md" \
	|| die "$STAGED was not produced by a dry run.
A real staging is committed by hand and proved by
scripts/verify-release-artifact-commit.sh on the actual commit; rehearsing it
here would prove a scratch clone instead of the tree the tag will name."

# The commit this artifact claims as its parent is the one the qualification
# recorded, not whatever HEAD happens to be: a dry run may run on a dirty tree,
# and verify-release-history.sh compares the commit's parent against exactly
# this field.
[ -f "$STAGED/QUALIFICATION" ] \
	|| die "$STAGED/QUALIFICATION is missing: nothing records which source commit was qualified"
mapfile -t source_lines < <(grep '^source_commit=' "$STAGED/QUALIFICATION" || true)
[ "${#source_lines[@]}" -eq 1 ] \
	|| die "QUALIFICATION must contain exactly one source_commit record"
SOURCE_COMMIT=${source_lines[0]#source_commit=}
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
	|| die "QUALIFICATION source_commit is not a full lowercase SHA-1: $SOURCE_COMMIT"
git -C "$REPO_ROOT" cat-file -e "$SOURCE_COMMIT^{commit}" 2>/dev/null \
	|| die "the qualified source commit is not in this repository: $SOURCE_COMMIT"

[ -f "$STAGED/commit_msg.txt" ] && [ -s "$STAGED/commit_msg.txt" ] \
	|| die "$STAGED/commit_msg.txt is missing or empty: the release run writes the message the artifact commit uses"

[ -d "$SCRATCH_PARENT" ] || die "scratch parent directory does not exist: $SCRATCH_PARENT"
CLONE=$(mktemp -d "$SCRATCH_PARENT/artifact-rehearsal.XXXXXX") \
	|| die "could not create a scratch directory under $SCRATCH_PARENT"

printf '\nrehearsing the %s artifact commit in %s\n\n' "$VERSION" "$CLONE"

# A local clone hardlinks its object store, so this costs a checkout rather
# than a copy of the history. Not --shared: an alternates-backed clone would
# depend on the real repository for the life of the rehearsal, and the gates
# below run a full release preflight inside it.
git clone --quiet --no-checkout "$REPO_ROOT" "$CLONE" \
	|| die "could not clone the repository into $CLONE"
git -C "$CLONE" checkout --quiet --detach "$SOURCE_COMMIT" \
	|| die "could not check out the qualified source commit $SOURCE_COMMIT in the clone"
ok "scratch clone checked out at the qualified source commit ${SOURCE_COMMIT:0:12}."

# The tag must not exist yet, in the clone as in the repository: the clone
# carries the real tags, so this is the same question the verifier asks, asked
# before an hour of gates rather than after.
if git -C "$CLONE" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
	die "refs/tags/$VERSION already exists: this version is spent, and the rehearsal would prove a shape that cannot be published"
fi
[ ! -e "$CLONE/release/$VERSION" ] \
	|| die "the qualified source commit already contains release/$VERSION: a release directory is added BY the artifact commit, never before it"

mkdir -p "$CLONE/release/$VERSION" \
	|| die "could not create release/$VERSION in the clone"
cp -a "$STAGED/." "$CLONE/release/$VERSION/" \
	|| die "could not copy the staged release directory into the clone"
ok "staged $VERSION copied into the clone exactly as an operator would commit it."

# The registry append, generated by the same command the handoff prints, from
# inside the clone so it describes the copied artifacts rather than the
# repository's own. Conditional for the same reason verify-release-history.sh
# makes it conditional: a source commit predating the registry owes no append.
REGISTRY=test/published_release_digests.txt
commit_paths=("release/$VERSION")
if git -C "$CLONE" cat-file -e "$SOURCE_COMMIT:$REGISTRY" 2>/dev/null; then
	( cd "$CLONE" && ./test/test_published_release_immutability.py \
		--print-record "$VERSION" >> "$REGISTRY" ) \
		|| die "could not generate the publication registration record"
	commit_paths+=("$REGISTRY")
	ok "appended one canonical publication registration to $REGISTRY."
fi

# gpgsign is disabled deliberately: this commit is scratch, nothing verifies
# its signature, and a signing prompt would block a rehearsal that is supposed
# to run unattended in the middle of a release. The identity is explicit so a
# host with no configured user can still rehearse.
git -C "$CLONE" add -- "${commit_paths[@]}" \
	|| die "could not stage the artifact commit in the clone"
git -C "$CLONE" \
	-c user.name='release rehearsal' \
	-c user.email='rehearsal@invalid' \
	-c commit.gpgsign=false \
	commit --quiet -F "$CLONE/release/$VERSION/commit_msg.txt" \
	|| die "could not create the artifact commit in the clone"
ok "artifact commit created on top of the qualified source: $(git -C "$CLONE" rev-parse --short HEAD)."

# The real verifier, on the real gates, in the clone. --allow-dry-run relaxes
# exactly the two things a dry run cannot have -- the banner in MANIFEST.md and
# the operator's signature -- and prints no tag or push command.
( cd "$CLONE" && ./scripts/verify-release-artifact-commit.sh --allow-dry-run "$VERSION" ) \
	|| die "the artifact-commit rehearsal FAILED in $CLONE.
This is the failure a real release would have hit after the soak, with the tag
already spent. The clone is kept for inspection; fix it in the source tree and
re-run the dry run."

ok "rehearsal clone kept at $CLONE"
