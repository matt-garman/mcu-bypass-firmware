#!/usr/bin/env bash
set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

# scripts/verify-release-artifact-commit.sh is the last gate before a release
# tag exists, and the ONLY thing that prints the tag and push commands. Two
# properties matter and neither is inspectable by reading it:
#
#   1. it refuses every unpublishable artifact commit, and
#   2. when it refuses, it prints nothing an operator could paste.
#
# A refusal that still printed the recipe would be a warning, not a gate --
# which is what the release path had before v0.9.12 was lost to it. Every
# negative case below therefore asserts BOTH the non-zero status and the
# absence of a tag command.
#
# The gates themselves are stubbed. What is under test is the decision, not
# the suite it dispatches; the real gate list is bound to the Makefile by
# test-makefile-name-contract, and its membership rule is stated beside it.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_SOURCE="$ROOT/scripts/verify-release-artifact-commit.sh"
POLICY_SOURCE="$ROOT/scripts/release-signing-policy.sh"
FINGERPRINT=6184219C6670945D7174F2B0149F042FCC3D3AEC
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-artifact-commit.XXXXXX")
repo="$work/repo"
# The stubs' control files and their record of what ran. Outside the repository
# on purpose: the script refuses a working tree that differs from HEAD at all,
# untracked files included, so a sentinel inside it would refuse every case for
# the wrong reason -- and would hide that refusal behind a passing test.
state="$work/state"
export ARTIFACT_FIXTURE_STATE="$state"
version=v9.9.9
checks=0
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

if ! command -v python3 >/dev/null 2>&1 \
   || ! python3 -c 'import yaml' >/dev/null 2>&1; then
	if [ -n "${STRICT_TOOLS:-}" ]; then
		printf 'ERROR: PyYAML absent and STRICT_TOOLS=1 (apt: python3-yaml)\n' >&2
		exit 1
	fi
	printf 'release artifact commit validation: SKIPPED (PyYAML absent; apt: python3-yaml)\n'
	exit 0
fi

# ---------------------------------------------------------------------------
# Fixture: a repository whose shape is the one the real script reads, with the
# two verifiers and the gate suite stubbed so each decision can be driven.
# ---------------------------------------------------------------------------
setup_fixture() {
	rm -rf "$repo" "$state"
	mkdir -p "$state"
	mkdir -p "$repo/scripts" "$repo/.github/workflows" "$repo/release/$version"
	cp "$SCRIPT_SOURCE" "$repo/scripts/verify-release-artifact-commit.sh"
	cp "$POLICY_SOURCE" "$repo/scripts/release-signing-policy.sh"
	chmod 755 "$repo/scripts/verify-release-artifact-commit.sh"
	mkdir -p "$repo/release"
	# release-signing-policy.sh resolves the public key relative to the repo,
	# and reads it; the value is not used by this script beyond the pinned
	# fingerprint, but the file must exist for the source to succeed.
	printf 'fixture public key\n' > "$repo/release/signing-key.asc"

	for stub in verify-release-signature.sh verify-release-history.sh; do
		cat > "$repo/scripts/$stub" <<-STUB
		#!/usr/bin/env bash
		if [ -f "\$ARTIFACT_FIXTURE_STATE/$stub.fail" ]; then
			printf 'stub $stub refuses\n' >&2
			exit 1
		fi
		exit 0
		STUB
		chmod 755 "$repo/scripts/$stub"
	done

	cat > "$repo/.github/workflows/release.yml" <<-'YAML'
	name: Release
	on:
	  push:
	    tags:
	      - 'v[0-9]+.[0-9]+.[0-9]+'
	env:
	  DEBIAN_FRONTEND: noninteractive
	  RELEASE_XT_STATIC_RAM_LIMIT: "16"
	  RELEASE_PIC12F675_DATA_LIMIT: "48"
	jobs:
	  release:
	    runs-on: ubuntu-24.04
	    steps:
	      - run: "true"
	YAML

	# The stub suite records exactly what it was asked to run, so the positive
	# case can assert the goals, the strictness flag and the pins actually
	# reached it rather than that the script exited zero.
	cat > "$repo/Makefile" <<'MAKEFILE'
RELEASE_ARTIFACT_GATES = gate-one gate-two

.PHONY: gate-one gate-two
gate-one gate-two:
	@printf '%s STRICT_TOOLS=%s XT_STATIC_RAM_LIMIT=%s PIC12F675_DATA_LIMIT=%s\n' \
		$@ "$(STRICT_TOOLS)" "$(XT_STATIC_RAM_LIMIT)" \
		"$(PIC12F675_DATA_LIMIT)" >> $(ARTIFACT_FIXTURE_STATE)/gates.log
	@test ! -f $(ARTIFACT_FIXTURE_STATE)/gates.fail

print-%:
	@echo '$($*)'
MAKEFILE

	for name in QUALIFICATION SHA256SUMS SHA256SUMS.asc MANIFEST.md README.md; do
		printf 'fixture %s\n' "$name" > "$repo/release/$version/$name"
	done

	git -C "$repo" init -q
	git -C "$repo" config user.name "Artifact Commit Test"
	git -C "$repo" config user.email "artifact-commit@example.invalid"
	git -C "$repo" add -A
	git -C "$repo" -c commit.gpgsign=false commit -qm artifact
}

run_verify() {
	(cd "$repo" && ./scripts/verify-release-artifact-commit.sh "$@" 2>&1)
}

expect_refusal() {
	local label=$1 expected=$2 output status=0
	shift 2
	output=$(run_verify "$@") || status=$?
	[ "$status" -ne 0 ] || fail "$label: an unpublishable commit was accepted"
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: refused for the wrong reason: $output"
	# The property the whole gate exists for: a refusal leaves the operator
	# with nothing to paste.
	[[ "$output" != *"git tag -s"* ]] \
		|| fail "$label: a refusal printed the tag command anyway"
	[[ "$output" != *"git push origin"* ]] \
		|| fail "$label: a refusal printed the push command anyway"
	checks=$((checks + 3))
}

# --- the publishable case ---------------------------------------------------
setup_fixture
output=$(run_verify "$version") || fail "a publishable artifact commit was refused: $output"
[[ "$output" == *"git tag -s -u $FINGERPRINT $version"* ]] \
	|| fail "the signed-tag command is not printed on success: $output"
[[ "$output" == *"git push origin $version"* ]] \
	|| fail "the push command is not printed on success: $output"
checks=$((checks + 3))

[ -f "$state/gates.log" ] || fail "the release-artifact gates never ran"
grep -q '^gate-one STRICT_TOOLS=1 XT_STATIC_RAM_LIMIT=16 PIC12F675_DATA_LIMIT=48$' \
	"$state/gates.log" \
	|| fail "the gates did not receive STRICT_TOOLS=1 and the workflow's pins: $(cat "$state/gates.log")"
grep -q '^gate-two ' "$state/gates.log" \
	|| fail "not every gate in RELEASE_ARTIFACT_GATES ran"
checks=$((checks + 3))

# --- the tree under test must be the tree the tag would name ----------------
setup_fixture
printf 'uncommitted\n' >> "$repo/release/$version/MANIFEST.md"
expect_refusal "uncommitted tracked change" "the working tree is not HEAD" "$version"

setup_fixture
printf 'staged for nothing\n' > "$repo/release/$version/evidence.log"
expect_refusal "untracked file the commit does not carry" \
	"the working tree is not HEAD" "$version"

setup_fixture
git -C "$repo" tag "$version"
expect_refusal "version already tagged" "already exists in this clone" "$version"

# --- the release directory --------------------------------------------------
setup_fixture
rm "$repo/release/$version/SHA256SUMS.asc"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm unsigned
expect_refusal "missing detached signature" "SHA256SUMS.asc is missing" "$version"

setup_fixture
printf 'DRY RUN -- NOT A VALIDATED RELEASE\n' >> "$repo/release/$version/MANIFEST.md"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm dry-run
expect_refusal "dry-run staging" "produced by a dry run" "$version"

setup_fixture
rm -rf "$repo/release/$version"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm no-release
expect_refusal "no release directory" "is missing or not a directory" "$version"

# --- the checks tag CI makes before it builds -------------------------------
setup_fixture
: > "$state/verify-release-signature.sh.fail"
expect_refusal "checksum signature does not verify" "does not verify against the pinned key" "$version"

setup_fixture
: > "$state/verify-release-history.sh.fail"
expect_refusal "not an artifact commit" "not a publishable release-artifact commit" "$version"

# --- the gates --------------------------------------------------------------
setup_fixture
: > "$state/gates.fail"
expect_refusal "a release-artifact gate fails" "gates failed on HEAD" "$version"

setup_fixture
cat > "$repo/Makefile" <<'MAKEFILE'
RELEASE_ARTIFACT_GATES =

print-%:
	@echo '$($*)'
MAKEFILE
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm empty-gates
expect_refusal "empty gate inventory" "RELEASE_ARTIFACT_GATES is empty" "$version"

# An inventory this script cannot read is not an empty one: a Makefile that
# fails to parse must refuse, not run zero gates and print the recipe.
setup_fixture
printf 'this is not a makefile\n' > "$repo/Makefile"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm broken-makefile
expect_refusal "unreadable gate inventory" "cannot read RELEASE_ARTIFACT_GATES" "$version"

# --- the independent pins ---------------------------------------------------
# The pins exist to be set apart from Make's production defaults so that a
# mismatch fails instead of agreeing with itself. A workflow that declares none
# would silently hand the gates those defaults back.
setup_fixture
python3 - "$repo/.github/workflows/release.yml" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()
text = "\n".join(line for line in text.splitlines()
                 if not line.strip().startswith("RELEASE_"))
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(text + "\n")
PY
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm unpinned
expect_refusal "workflow declares no pins" "declares no RELEASE_* pins" "$version"

# --- arguments --------------------------------------------------------------
setup_fixture
expect_refusal "malformed version" "invalid release version" "9.9.9"

status=0
output=$( (cd "$repo" && ./scripts/verify-release-artifact-commit.sh 2>&1) ) || status=$?
[ "$status" -eq 2 ] || fail "a missing version argument did not exit 2"
[[ "$output" == *"usage:"* ]] || fail "a missing version argument printed no usage"
checks=$((checks + 2))

printf 'release artifact commit validation: %d checks, 0 failures\n' "$checks"
