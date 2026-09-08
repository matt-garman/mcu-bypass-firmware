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

# No optional-tool guard: this suite needs bash, git and make and nothing else.
# It used to skip without PyYAML, because the script parsed release.yml for the
# independent pins it handed the gates. It passes no pins now, so a skip here
# would be a gate declining to run for a reason that has ceased to exist.

# ---------------------------------------------------------------------------
# Fixture: a repository whose shape is the one the real script reads, with the
# two verifiers and the gate suite stubbed so each decision can be driven.
# ---------------------------------------------------------------------------
setup_fixture() {
	rm -rf "$repo" "$state"
	mkdir -p "$state"
	mkdir -p "$repo/scripts" "$repo/release/$version"
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

	# Deliberately NO .github/workflows/release.yml. The script used to read
	# that file for the pins it handed the gates; a fixture that still shipped
	# one would let a re-introduced dependency on it pass unnoticed.

	# The stub suite records exactly what it was asked to run, so the positive
	# case can assert the goals, the strictness flag and the pins actually
	# reached it rather than that the script exited zero.
	# release-artifact-gates is spelled here as the real Makefile spells it:
	# the script now invokes the GOAL, so a fixture that dispatched the gates
	# some other way would stop testing what the script does. That the real
	# recipe still reads this way is asserted separately, against the recipe,
	# in test_workflow_syntax.sh.
	cat > "$repo/Makefile" <<'MAKEFILE'
RELEASE_ARTIFACT_GATES = gate-one gate-two

.PHONY: release-artifact-gates gate-one gate-two
release-artifact-gates:
	$(if $(strip $(RELEASE_ARTIFACT_GATES)),,$(error RELEASE_ARTIFACT_GATES is empty))
	$(MAKE) $(RELEASE_ARTIFACT_GATES) STRICT_TOOLS=1

# PINS reports the NAMES of every command-line variable that reached the gate
# other than the one the goal owns. Reporting names rather than the values of
# two variables chosen in advance is what makes the assertion complete: a pin
# nobody thought to probe for is still reported, by name, the day it is added.
# `origin` is the distinction that matters -- a caller's exported build input is
# ENVIRONMENT origin and no business of this gate, while anything the dispatch
# put on a command line, directly or re-passed through MAKEFLAGS, is COMMAND
# LINE and is exactly what must not be here. The -% filter drops make's internal
# -*-command-variables-*- bookkeeping, which is not a pin anyone passed.
gate-one gate-two:
	@printf '%s STRICT_TOOLS=%s PINS=[%s]\n' $@ "$(STRICT_TOOLS)" \
		"$(strip $(foreach v,$(.VARIABLES),$(if $(filter command line,$(origin $(v))),$(filter-out STRICT_TOOLS -%,$(v)))))" \
		>> $(ARTIFACT_FIXTURE_STATE)/gates.log
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
# STRICT_TOOLS=1 is the whole of the policy the goal owns, and it must reach
# every gate: one that skipped for want of a tool would otherwise help report a
# release publishable on evidence nobody gathered.
grep -q '^gate-one STRICT_TOOLS=1 PINS=\[\]$' "$state/gates.log" \
	|| fail "the gates did not receive STRICT_TOOLS=1, or received a pin: $(cat "$state/gates.log")"
grep -q '^gate-two ' "$state/gates.log" \
	|| fail "not every gate in RELEASE_ARTIFACT_GATES ran"
# The empty PINS field is an assertion, not an accident. The script used to hand
# these gates release.yml's independent pins; none of the eight reads one, and
# they reached the gates' own nested Makes as unreviewed build input by the
# release guard's own definition. Passing them again must be a deliberate act
# that fails here first.
checks=$((checks + 3))

# --- nor may a pin arrive through the CALLER ---------------------------------
# The goal passing no pins is half the guarantee; the other half is that none
# arrives through the environment this script was started in. That half was
# missing. GNU Make re-passes every command-line variable to its sub-makes
# through MAKEFLAGS, so a release -- which runs `make test-long ...
# XT_STATIC_RAM_LIMIT=16 PIC12F675_DATA_LIMIT=48` -- handed both to these gates
# as COMMAND-LINE origin from three levels up, and a release is the one caller
# that always has them set. The first real `make-release.sh --dry-run` failed on
# the assertion above for exactly that reason, half an hour into the run.
#
# The build inputs are exported here as well, and must NOT be reported: those
# are ENVIRONMENT origin, which is the gates' own business. Clearing them would
# be the wrong repair -- it would leave the MAKEFLAGS channel open and make this
# case pass whether or not the dispatch was scrubbed.
setup_fixture
output=$(
	export XT_STATIC_RAM_LIMIT=16 PIC12F675_DATA_LIMIT=48
	export MAKEFLAGS=" -- XT_STATIC_RAM_LIMIT=16 PIC12F675_DATA_LIMIT=48"
	export MAKELEVEL=2
	run_verify "$version"
) || fail "a publishable artifact commit was refused under a release's own Make environment: $output"
grep -q '^gate-one STRICT_TOOLS=1 PINS=\[\]$' "$state/gates.log" \
	|| fail "an inherited command-line variable reached the gates: $(cat "$state/gates.log")"
grep -q '^gate-two STRICT_TOOLS=1 PINS=\[\]$' "$state/gates.log" \
	|| fail "an inherited command-line variable reached the gates: $(cat "$state/gates.log")"
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

# --- the rehearsal mode -----------------------------------------------------
# --allow-dry-run is how scripts/rehearse-artifact-commit.sh runs this script
# against a scratch clone during a dry run, an hour into a release rather than
# a day. It must relax exactly two things -- the banner a dry-run MANIFEST
# carries, and the signature a dry run has not made -- and nothing else. The
# refusals below are the same cases already proved above, re-proved with the
# flag set, because a rehearsal that accepts what the real thing refuses would
# report a shape publishable that is not.
stage_dry_run() {
	printf 'DRY RUN -- NOT A VALIDATED RELEASE\n' >> "$repo/release/$version/MANIFEST.md"
	rm -f "$repo/release/$version/SHA256SUMS.asc"
	git -C "$repo" add -A
	git -C "$repo" -c commit.gpgsign=false commit -qm dry-run-staging
}

setup_fixture
stage_dry_run
output=$(run_verify --allow-dry-run "$version") \
	|| fail "a dry-run staging was refused in rehearsal mode: $output"
# The two relaxations, each named in the output rather than silent: a rehearsal
# that does not say what it skipped is how one comes to be read as a release.
[[ "$output" == *"NOT PROVEN"* ]] \
	|| fail "the rehearsal did not report the signature as unproven: $output"
[[ "$output" == *"rehearsal passed"* ]] \
	|| fail "the rehearsal printed no verdict: $output"
# And the property that makes the flag safe to have at all.
[[ "$output" != *"git tag -s"* ]] \
	|| fail "the rehearsal printed the tag command"
[[ "$output" != *"git push origin"* ]] \
	|| fail "the rehearsal printed the push command"
checks=$((checks + 5))

# The gates are the expensive half and the whole reason to rehearse: they must
# run here exactly as they run for a publishable verdict.
grep -q '^gate-one STRICT_TOOLS=1 PINS=\[\]$' "$state/gates.log" \
	|| fail "the rehearsal did not run the gates under the real policy: $(cat "$state/gates.log")"
grep -q '^gate-two ' "$state/gates.log" \
	|| fail "the rehearsal did not run every gate in RELEASE_ARTIFACT_GATES"
checks=$((checks + 2))

# The flag REQUIRES the banner it permits. Without this it would be a way to
# accept a publishable staging under weaker rules -- signature not verified --
# and print a passing verdict for it.
setup_fixture
expect_refusal "rehearsal mode on a publishable staging" \
	"carries no dry-run banner" --allow-dry-run "$version"

# Everything else the flag must NOT relax. Each of these is refused above
# without the flag; the point here is that the rehearsal refuses them too.
setup_fixture
stage_dry_run
printf 'uncommitted\n' >> "$repo/release/$version/MANIFEST.md"
expect_refusal "rehearsal with a dirty tree" "the working tree is not HEAD" \
	--allow-dry-run "$version"

setup_fixture
stage_dry_run
git -C "$repo" tag "$version"
expect_refusal "rehearsal of an already-tagged version" "already exists in this clone" \
	--allow-dry-run "$version"

setup_fixture
stage_dry_run
rm "$repo/release/$version/QUALIFICATION"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm no-qualification
expect_refusal "rehearsal without QUALIFICATION" "QUALIFICATION is missing" \
	--allow-dry-run "$version"

setup_fixture
stage_dry_run
: > "$state/verify-release-history.sh.fail"
expect_refusal "rehearsal of a commit that is not an artifact commit" \
	"not a publishable release-artifact commit" --allow-dry-run "$version"

setup_fixture
stage_dry_run
: > "$state/gates.fail"
expect_refusal "rehearsal with a failing gate" "gates failed on HEAD" \
	--allow-dry-run "$version"

# A signature the dry run somehow DOES carry is still verified: the flag
# permits the file to be absent, it does not stop checking one that is present.
setup_fixture
printf 'DRY RUN -- NOT A VALIDATED RELEASE\n' >> "$repo/release/$version/MANIFEST.md"
git -C "$repo" add -A
git -C "$repo" -c commit.gpgsign=false commit -qm dry-run-signed
: > "$state/verify-release-signature.sh.fail"
expect_refusal "rehearsal with a signature that does not verify" \
	"does not verify against the pinned key" --allow-dry-run "$version"

# --- arguments --------------------------------------------------------------
setup_fixture
expect_refusal "malformed version" "invalid release version" "9.9.9"

status=0
output=$( (cd "$repo" && ./scripts/verify-release-artifact-commit.sh 2>&1) ) || status=$?
[ "$status" -eq 2 ] || fail "a missing version argument did not exit 2"
[[ "$output" == *"usage:"* ]] || fail "a missing version argument printed no usage"
checks=$((checks + 2))

printf 'release artifact commit validation: %d checks, 0 failures\n' "$checks"
