#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE_VERIFY="$ROOT/scripts/verify-release-history.sh"
TAG_VERIFY="$ROOT/scripts/verify-release-tag-target.sh"
WORKFLOW="$ROOT/.github/workflows/release.yml"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-history.XXXXXX")
repo="$work/repo"
snapshot="$work/snapshot"
version=v99.0.0
checks=0
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

setup_fixture() {
	local source_mode=${1:-source}
	local extra_path=${2:-none}
	local merge_mode=${3:-no-merge}
	local prior_release=${4:-absent}
	local qsource primary
	rm -rf "$repo" "$snapshot"
	mkdir -p "$repo/scripts"
	cp "$SOURCE_VERIFY" "$repo/scripts/verify-release-history.sh"
	chmod 755 "$repo/scripts/verify-release-history.sh"
	git -C "$repo" init -q
	git -C "$repo" config user.name "Release History Test"
	git -C "$repo" config user.email "release-history@example.invalid"
	printf 'base\n' > "$repo/base.txt"
	git -C "$repo" add base.txt scripts/verify-release-history.sh
	git -C "$repo" -c commit.gpgsign=false commit -qm base
	base_sha=$(git -C "$repo" rev-parse HEAD)
	primary=$(git -C "$repo" symbolic-ref --short HEAD)

	printf 'qualified source\n' > "$repo/source.txt"
	git -C "$repo" add source.txt
	git -C "$repo" -c commit.gpgsign=false commit -qm source
	source_sha=$(git -C "$repo" rev-parse HEAD)
	if [ "$prior_release" = preexisting ]; then
		mkdir -p "$repo/release/$version"
		printf 'source_commit=%s\n' "$base_sha" > "$repo/release/$version/QUALIFICATION"
		git -C "$repo" add "release/$version/QUALIFICATION"
		git -C "$repo" -c commit.gpgsign=false commit -qm preexisting-release
		source_sha=$(git -C "$repo" rev-parse HEAD)
	elif [ "$prior_release" != absent ]; then
		fail "bad prior-release mode in fixture: $prior_release"
	fi

	if [ "$merge_mode" = merge ]; then
		git -C "$repo" checkout -qb side
		mkdir -p "$repo/release/$version"
		printf 'side artifact\n' > "$repo/release/$version/side.txt"
		git -C "$repo" add "release/$version/side.txt"
		git -C "$repo" -c commit.gpgsign=false commit -qm side
		git -C "$repo" checkout -q "$primary"
	fi

	case "$source_mode" in
		source) qsource=$source_sha ;;
		base) qsource=$base_sha ;;
		*) fail "bad source mode in fixture: $source_mode" ;;
	esac
	mkdir -p "$repo/release/$version/evidence"
	printf 'source_commit=%s\n' "$qsource" > "$repo/release/$version/QUALIFICATION"
	printf 'manifest\n' > "$repo/release/$version/MANIFEST.md"
	printf 'evidence\n' > "$repo/release/$version/evidence/result.log"
	git -C "$repo" add "release/$version"
	if [ "$extra_path" = outside ]; then
		printf 'not release data\n' > "$repo/outside.txt"
		git -C "$repo" add outside.txt
	elif [ "$extra_path" = sibling ]; then
		mkdir -p "$repo/release/other"
		printf 'wrong release\n' > "$repo/release/other/file.txt"
		git -C "$repo" add release/other/file.txt
	fi
	git -C "$repo" -c commit.gpgsign=false commit -qm release
	if [ "$merge_mode" = merge ]; then
		git -C "$repo" -c commit.gpgsign=false merge -q --no-ff side -m merge
	fi
	release_sha=$(git -C "$repo" rev-parse HEAD)
	cp -a "$repo/release/$version" "$snapshot"
}

expect_pass() {
	local label=$1
	"$repo/scripts/verify-release-history.sh" "$snapshot" "$version" "$release_sha" \
		>/dev/null || fail "$label: valid release history was rejected"
	checks=$((checks + 1))
}

expect_fail() {
	local label=$1 expected=$2
	shift 2
	local output
	if output=$("$repo/scripts/verify-release-history.sh" "$@" 2>&1); then
		fail "$label: invalid release history was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

setup_fixture
expect_pass "artifact-only child of qualified source"

git -C "$repo" tag -a event-object -m "annotated event" "$release_sha"
tag_object=$(git -C "$repo" rev-parse refs/tags/event-object)
"$repo/scripts/verify-release-history.sh" "$snapshot" "$version" "$tag_object" \
	>/dev/null || fail "annotated event object did not peel to the release commit"
checks=$((checks + 1))

setup_fixture base
expect_fail "qualification names a non-parent source" "parent does not match" \
	"$snapshot" "$version" "$release_sha"

setup_fixture source outside
expect_fail "release commit changes source path" "outside release/$version/" \
	"$snapshot" "$version" "$release_sha"

setup_fixture source sibling
expect_fail "release commit changes another release" "outside release/$version/" \
	"$snapshot" "$version" "$release_sha"

setup_fixture source none merge
expect_fail "merge release commit" "exactly one parent" \
	"$snapshot" "$version" "$release_sha"

setup_fixture source none no-merge preexisting
expect_fail "qualified source already contains release record" "already contains" \
	"$snapshot" "$version" "$release_sha"

setup_fixture
git -C "$repo" checkout -q "$source_sha"
expect_fail "workflow checkout differs from release commit" "HEAD is not the release commit" \
	"$snapshot" "$version" "$release_sha"

setup_fixture
printf 'extra snapshot data\n' >> "$snapshot/QUALIFICATION"
expect_fail "snapshot differs from tagged qualification" "snapshot differs" \
	"$snapshot" "$version" "$release_sha"

setup_fixture
expect_fail "wrong release version path" "outside release/v99.0.1/" \
	"$snapshot" v99.0.1 "$release_sha"

setup_fixture
expect_fail "malformed release object" "not a full lowercase SHA-1" \
	"$snapshot" "$version" not-a-sha

grep -Fq 'fetch-depth: 2' "$WORKFLOW" \
	|| fail "release workflow does not fetch the qualified source parent"
grep -Fq 'RELEASE_OBJECT: ${{ github.sha }}' "$WORKFLOW" \
	|| fail "release workflow does not route the independent event object"
grep -Fq 'scripts/verify-release-history.sh "$dir" "$tag" "$RELEASE_OBJECT"' "$WORKFLOW" \
	|| fail "release workflow does not bind qualification to tag history"
grep -Fq 'scripts/verify-release-tag-target.sh origin "$tag" "$VERIFIED_RELEASE_COMMIT"' "$WORKFLOW" \
	|| fail "release workflow does not recheck the remote tag before publication"
checks=$((checks + 1))

# Remote resolution accepts both lightweight and annotated tags, but not a moved
# or missing one. A local bare remote makes this deterministic and network-free.
setup_fixture
remote="$work/remote.git"
git init -q --bare "$remote"
git -C "$repo" tag "$version" "$release_sha"
git -C "$repo" push -q "$remote" "refs/tags/$version"
"$TAG_VERIFY" "$remote" "$version" "$release_sha" >/dev/null \
	|| fail "remote lightweight release tag was rejected"
checks=$((checks + 1))

git -C "$repo" tag -f "$version" "$source_sha" >/dev/null
git -C "$repo" push -q --force "$remote" "refs/tags/$version"
if output=$("$TAG_VERIFY" "$remote" "$version" "$release_sha" 2>&1); then
	fail "moved remote release tag was accepted"
fi
[[ "$output" == *"remote tag $version moved"* ]] \
	|| fail "moved remote tag failed for the wrong reason: $output"
checks=$((checks + 1))

git -C "$repo" tag -fa "$version" -m "annotated release" "$release_sha" >/dev/null
git -C "$repo" push -q --force "$remote" "refs/tags/$version"
"$TAG_VERIFY" "$remote" "$version" "$release_sha" >/dev/null \
	|| fail "remote annotated release tag did not peel to the verified commit"
checks=$((checks + 1))

if output=$("$TAG_VERIFY" "$remote" v99.0.1 "$release_sha" 2>&1); then
	fail "missing remote release tag was accepted"
fi
[[ "$output" == *"missing or ambiguous"* ]] \
	|| fail "missing remote tag failed for the wrong reason: $output"
checks=$((checks + 1))

printf 'release history validation: %d checks, 0 failures\n' "$checks"
