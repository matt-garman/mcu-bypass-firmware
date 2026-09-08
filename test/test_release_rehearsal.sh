#!/usr/bin/env bash
set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

# scripts/rehearse-artifact-commit.sh builds the release-artifact commit SHAPE
# in a scratch clone during a dry run, so the gates that can only run on that
# commit run an hour into a release instead of a day into one. v0.9.12 is what
# skipping it costs: tagged, pushed, and then refused on its own tree.
#
# Two properties are under test here, and neither is inspectable by reading it:
#
#   1. the commit it assembles is the one a tag would name -- a single-parent
#      child of the QUALIFIED SOURCE commit, changing only release/<version>/
#      plus one appended publication registration; and
#   2. it refuses every input that could make that shape a lie, rather than
#      rehearsing something the real release will not do.
#
# The verifier is stubbed. What runs against the real gates is proved in
# test_release_artifact_commit.sh, including the --allow-dry-run mode this
# script depends on; what is under test here is the shape handed to it.
#
# Everything happens in a scratch repository, and each case re-asserts that the
# real repository was not touched -- the script's own first claim.

# Byte collation, so the path list below is compared in the order git emits it
# rather than in whatever order the caller's locale prefers.
LC_ALL=C
export LC_ALL

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_SOURCE="$ROOT/scripts/rehearse-artifact-commit.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-rehearsal.XXXXXX")
repo="$work/repo"
staged="$work/staged"
scratch="$work/scratch"
state="$work/state"
export REHEARSAL_FIXTURE_STATE="$state"
version=v9.9.9
checks=0
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# No optional-tool guard: bash, git and python3 are all this needs, and python3
# only because the fixture's registry stub is written in it.
command -v git >/dev/null 2>&1 || fail "git is required"

# ---------------------------------------------------------------------------
# Fixture: a repository with one commit standing in for the qualified source,
# and a staged directory standing in for a dry run's output.
# ---------------------------------------------------------------------------
setup_fixture() {
	rm -rf "$repo" "$staged" "$scratch" "$state"
	mkdir -p "$state" "$scratch" "$repo/scripts" "$repo/test" "$staged"
	cp "$SCRIPT_SOURCE" "$repo/scripts/rehearse-artifact-commit.sh"
	chmod 755 "$repo/scripts/rehearse-artifact-commit.sh"

	# The verifier records what it was asked to prove, and where from. A
	# rehearsal that ran it in the wrong tree would otherwise pass every
	# assertion below while proving the repository instead of the clone.
	cat > "$repo/scripts/verify-release-artifact-commit.sh" <<-'STUB'
	#!/usr/bin/env bash
	{
		printf 'argv: %s\n' "$*"
		printf 'cwd: %s\n' "$PWD"
		printf 'head: %s\n' "$(git rev-parse HEAD)"
	} >> "$REHEARSAL_FIXTURE_STATE/verifier.log"
	[ ! -f "$REHEARSAL_FIXTURE_STATE/verifier.fail" ] || {
		printf 'stub verifier refuses\n' >&2
		exit 1
	}
	exit 0
	STUB
	chmod 755 "$repo/scripts/verify-release-artifact-commit.sh"

	# The registry generator, stubbed to one deterministic line so the append
	# can be asserted exactly. The real one hashes the staged artifacts; that
	# is test_published_release_immutability.py's own subject.
	cat > "$repo/test/test_published_release_immutability.py" <<-'STUB'
	#!/usr/bin/env python3
	import sys
	if sys.argv[1:2] == ["--print-record"]:
	    print(f"record for {sys.argv[2]}")
	    raise SystemExit(0)
	raise SystemExit(2)
	STUB
	chmod 755 "$repo/test/test_published_release_immutability.py"
	printf 'existing registry content\n' > "$repo/test/published_release_digests.txt"

	git -C "$repo" init -q
	git -C "$repo" config user.name "Release Rehearsal Test"
	git -C "$repo" config user.email "rehearsal@example.invalid"
	git -C "$repo" add -A
	git -C "$repo" -c commit.gpgsign=false commit -qm source
	SOURCE_COMMIT=$(git -C "$repo" rev-parse HEAD)

	# The staged dry-run output: the banner, the source commit it claims, and
	# the message the artifact commit is made with.
	printf 'source_commit=%s\n' "$SOURCE_COMMIT" > "$staged/QUALIFICATION"
	printf '> **DRY RUN -- NOT A VALIDATED RELEASE.**\n\n# Manifest\n' \
		> "$staged/MANIFEST.md"
	printf 'release %s\n' "$version" > "$staged/commit_msg.txt"
	printf 'artifact payload\n' > "$staged/bypass-fixture.hex"
}

run_rehearsal() {
	(cd "$repo" && ./scripts/rehearse-artifact-commit.sh "$@" 2>&1)
}

# The script's own first claim: it touches nothing in the repository it is run
# from. Re-asserted after every case, because a rehearsal that committed to the
# real repo would be the single worst outcome available to it.
assert_repo_untouched() {
	local label=$1 head status
	head=$(git -C "$repo" rev-parse HEAD)
	[ "$head" = "$SOURCE_COMMIT" ] \
		|| fail "$label: the repository's HEAD moved from $SOURCE_COMMIT to $head"
	status=$(git -C "$repo" status --porcelain)
	[ -z "$status" ] || fail "$label: the repository's working tree was modified:
$status"
	checks=$((checks + 2))
}

expect_refusal() {
	local label=$1 expected=$2 output status=0
	shift 2
	output=$(run_rehearsal "$@") || status=$?
	[ "$status" -ne 0 ] || fail "$label: a rehearsal that cannot be trusted was accepted"
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: refused for the wrong reason: $output"
	checks=$((checks + 2))
	assert_repo_untouched "$label"
}

clone_path() {
	# The script prints the clone it built; every assertion about the shape
	# reads it back from there.
	sed -n 's/^rehearsing the .* in \(.*\)$/\1/p' <<<"$1" | tail -1
}

# --- the shape it assembles -------------------------------------------------
setup_fixture
output=$(run_rehearsal "$staged" "$version" "$scratch") \
	|| fail "a valid dry-run staging was refused: $output"
clone=$(clone_path "$output")
[ -n "$clone" ] && [ -d "$clone" ] || fail "the rehearsal printed no usable clone path: $output"
checks=$((checks + 1))

# One parent, and it is the commit the QUALIFICATION names -- not whatever HEAD
# happened to be, which for a dry run may not even be committed.
read -r -a ancestry <<<"$(git -C "$clone" rev-list --parents -n 1 HEAD)"
[ "${#ancestry[@]}" -eq 2 ] \
	|| fail "the artifact commit does not have exactly one parent: ${ancestry[*]}"
[ "${ancestry[1]}" = "$SOURCE_COMMIT" ] \
	|| fail "the artifact commit's parent is ${ancestry[1]}, not the qualified source $SOURCE_COMMIT"
checks=$((checks + 2))

# Only the two paths a tag is allowed to publish.
mapfile -t changed < <(git -C "$clone" diff-tree --no-commit-id --name-only -r HEAD | sort)
expected_changed=$(printf 'release/%s/MANIFEST.md\nrelease/%s/QUALIFICATION\nrelease/%s/bypass-fixture.hex\nrelease/%s/commit_msg.txt\ntest/published_release_digests.txt\n' \
	"$version" "$version" "$version" "$version")
[ "$(printf '%s\n' "${changed[@]}")" = "$expected_changed" ] \
	|| fail "the artifact commit changes the wrong paths:
$(printf '%s\n' "${changed[@]}")"
checks=$((checks + 1))

# The staged directory arrives byte for byte -- including commit_msg.txt, which
# a real release commits along with everything else it staged.
cmp -s "$staged/bypass-fixture.hex" "$clone/release/$version/bypass-fixture.hex" \
	|| fail "the staged artifact was not copied verbatim"
[ "$(git -C "$clone" log -1 --pretty=%s)" = "release $version" ] \
	|| fail "the artifact commit does not use the staged commit message"
checks=$((checks + 2))

# Exactly one appended registration, with the parent's bytes intact.
registry="$clone/test/published_release_digests.txt"
[ "$(cat "$registry")" = "existing registry content
record for $version" ] \
	|| fail "the registry was not appended exactly once: $(cat "$registry")"
checks=$((checks + 1))

# Nothing it made is left uncommitted. The real verifier refuses a tree that
# differs from HEAD at all, untracked files included, so a rehearsal that left
# one behind would fail there for a reason that has nothing to do with the
# release -- and a rehearsal that committed one would rehearse the wrong shape.
[ -z "$(git -C "$clone" status --porcelain)" ] \
	|| fail "the rehearsal left the clone dirty: $(git -C "$clone" status --porcelain)"
checks=$((checks + 1))

# The verifier ran, in rehearsal mode, in the CLONE, on the commit just made.
verifier_log="$state/verifier.log"
[ -f "$verifier_log" ] || fail "the rehearsal never ran the verifier"
grep -q "^argv: --allow-dry-run $version$" "$verifier_log" \
	|| fail "the verifier was not asked to rehearse: $(cat "$verifier_log")"
grep -q "^cwd: $clone$" "$verifier_log" \
	|| fail "the verifier ran outside the clone: $(cat "$verifier_log")"
grep -q "^head: $(git -C "$clone" rev-parse HEAD)$" "$verifier_log" \
	|| fail "the verifier did not run on the artifact commit: $(cat "$verifier_log")"
checks=$((checks + 4))
assert_repo_untouched "the shape it assembles"

# --- the qualified source, not the branch tip -------------------------------
# A dry run may be started on a tree whose HEAD has since moved, and the
# artifact commit's parent is required to be the commit the QUALIFICATION
# names. Cloning "the default branch" would pass every other assertion here
# while building a commit verify-release-history.sh rejects.
setup_fixture
qualified=$SOURCE_COMMIT
printf 'later work\n' > "$repo/later.txt"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm later
SOURCE_COMMIT=$(git -C "$repo" rev-parse HEAD)
output=$(run_rehearsal "$staged" "$version" "$scratch") \
	|| fail "a staging whose source commit is not the branch tip was refused: $output"
clone=$(clone_path "$output")
read -r -a ancestry <<<"$(git -C "$clone" rev-list --parents -n 1 HEAD)"
[ "${ancestry[1]}" = "$qualified" ] \
	|| fail "the rehearsal built on ${ancestry[1]}, not on the qualified source $qualified"
[ ! -e "$clone/later.txt" ] \
	|| fail "the clone carries work committed after the qualified source"
checks=$((checks + 2))
assert_repo_untouched "the qualified source, not the branch tip"

# --- a source commit that predates the registry -----------------------------
# verify-release-history.sh makes the append conditional on the parent carrying
# the registry at all, so the rehearsal has to be conditional the same way, or
# it would rehearse a commit shape the verifier would reject.
setup_fixture
git -C "$repo" rm -q test/published_release_digests.txt
git -C "$repo" -c commit.gpgsign=false commit -qm no-registry
SOURCE_COMMIT=$(git -C "$repo" rev-parse HEAD)
printf 'source_commit=%s\n' "$SOURCE_COMMIT" > "$staged/QUALIFICATION"
output=$(run_rehearsal "$staged" "$version" "$scratch") \
	|| fail "a legacy staging with no registry was refused: $output"
clone=$(clone_path "$output")
mapfile -t changed < <(git -C "$clone" diff-tree --no-commit-id --name-only -r HEAD)
for path in "${changed[@]}"; do
	[[ "$path" == "release/$version/"* ]] \
		|| fail "a registry-less rehearsal changed $path"
done
checks=$((checks + 1))
assert_repo_untouched "a source commit that predates the registry"

# --- what it must refuse ----------------------------------------------------
# A rehearsal rehearses a DRY RUN. Pointed at a real staging it would assemble
# something that looks publishable, in a throwaway clone, from a tree nobody
# will tag.
setup_fixture
printf '# Manifest\n' > "$staged/MANIFEST.md"
expect_refusal "a staging with no dry-run banner" "was not produced by a dry run" \
	"$staged" "$version" "$scratch"

setup_fixture
rm "$staged/MANIFEST.md"
expect_refusal "a staging with no manifest" "MANIFEST.md is missing" \
	"$staged" "$version" "$scratch"

setup_fixture
rm "$staged/QUALIFICATION"
expect_refusal "a staging with no qualification" \
	"nothing records which source commit was qualified" \
	"$staged" "$version" "$scratch"

setup_fixture
printf 'no source commit here\n' > "$staged/QUALIFICATION"
expect_refusal "a qualification with no source commit" \
	"exactly one source_commit record" "$staged" "$version" "$scratch"

setup_fixture
printf 'source_commit=deadbeef\n' > "$staged/QUALIFICATION"
expect_refusal "a truncated source commit" "not a full lowercase SHA-1" \
	"$staged" "$version" "$scratch"

setup_fixture
printf 'source_commit=%s\n' "0000000000000000000000000000000000000000" \
	> "$staged/QUALIFICATION"
expect_refusal "a source commit this repository does not have" \
	"not in this repository" "$staged" "$version" "$scratch"

setup_fixture
rm "$staged/commit_msg.txt"
expect_refusal "a staging with no commit message" "commit_msg.txt is missing" \
	"$staged" "$version" "$scratch"

# The tag is the thing a release spends. Rehearsing a version that already has
# one would prove a shape that can never be published.
setup_fixture
git -C "$repo" tag "$version"
expect_refusal "a version that is already tagged" "already exists" \
	"$staged" "$version" "$scratch"

# A release directory is added BY the artifact commit. One already present in
# the source tree means the qualified source is not the parent this staging
# claims.
setup_fixture
mkdir -p "$repo/release/$version"
printf 'stale\n' > "$repo/release/$version/QUALIFICATION"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm stale-release
SOURCE_COMMIT=$(git -C "$repo" rev-parse HEAD)
printf 'source_commit=%s\n' "$SOURCE_COMMIT" > "$staged/QUALIFICATION"
expect_refusal "a source commit that already contains the release" \
	"already contains release/$version" "$staged" "$version" "$scratch"

setup_fixture
expect_refusal "a malformed version" "invalid release version" \
	"$staged" "9.9.9" "$scratch"

setup_fixture
expect_refusal "a staging directory that does not exist" \
	"staged release directory is missing" "$work/nowhere" "$version" "$scratch"

# --- the verifier's verdict is the rehearsal's verdict ----------------------
# The whole point is to fail here rather than after the soak, so a refusal must
# propagate, and the clone must survive for the operator to look at.
setup_fixture
: > "$state/verifier.fail"
status=0
output=$(run_rehearsal "$staged" "$version" "$scratch") || status=$?
[ "$status" -ne 0 ] || fail "a failing verifier did not fail the rehearsal"
[[ "$output" == *"rehearsal FAILED"* ]] \
	|| fail "a failing rehearsal did not say so: $output"
clone=$(clone_path "$output")
[ -d "$clone" ] || fail "a failing rehearsal did not keep its clone for inspection"
[ -f "$clone/release/$version/QUALIFICATION" ] \
	|| fail "the kept clone does not carry the assembled artifact commit"
checks=$((checks + 4))
assert_repo_untouched "the verifier's verdict is the rehearsal's verdict"

# --- arguments --------------------------------------------------------------
setup_fixture
status=0
output=$( (cd "$repo" && ./scripts/rehearse-artifact-commit.sh 2>&1) ) || status=$?
[ "$status" -eq 2 ] || fail "a missing argument did not exit 2"
[[ "$output" == *"usage:"* ]] || fail "a missing argument printed no usage"
checks=$((checks + 2))

printf 'release rehearsal validation: %d checks, 0 failures\n' "$checks"
