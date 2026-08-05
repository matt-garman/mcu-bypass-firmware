#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE_VERIFY="$ROOT/scripts/verify-release-history.sh"
TAG_VERIFY_SOURCE="$ROOT/scripts/verify-release-tag-target.sh"
SIGNATURE_VERIFY_SOURCE="$ROOT/scripts/verify-release-signature.sh"
PINNED_SIGNATURE_VERIFY="$SIGNATURE_VERIFY_SOURCE"
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

create_signing_key() {
	local home=$1 uid=$2 public_key=$3 result_var=$4 fingerprint
	install -d -m 700 "$home"
	gpg --batch --no-options --homedir "$home" --pinentry-mode loopback \
		--passphrase '' --quick-generate-key "$uid" ed25519 sign 1d \
		>/dev/null 2>&1 || fail "could not generate $uid signing fixture"
	fingerprint=$(gpg --batch --no-options --homedir "$home" --with-colons \
		--fingerprint --list-secret-keys 2>/dev/null \
		| awk -F: '$1 == "fpr" { print $10; exit }')
	[[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] \
		|| fail "could not read $uid fixture fingerprint"
	gpg --batch --no-options --homedir "$home" --armor \
		--export "$fingerprint" > "$public_key" \
		|| fail "could not export $uid public key"
	printf -v "$result_var" '%s' "$fingerprint"
}

run_signature_verify() {
	"$SIGNATURE_VERIFY" "$@"
}

expect_signature_fail() {
	local label=$1 expected=$2 output
	shift 2
	if output=$(run_signature_verify "$@" 2>&1); then
		fail "$label: invalid release signature was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

run_tag_verify() {
	"$TAG_VERIFY" "$@"
}

status_policy_accepts() (
	# shellcheck source=/dev/null
	source "$verifier_fixture/scripts/release-signing-policy.sh"
	release_signature_status_matches_policy "$1"
)

expect_tag_fail() {
	local label=$1 expected=$2 output
	if output=$(run_tag_verify "$remote" "$version" "$release_sha" 2>&1); then
		fail "$label: invalid remote release tag was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

push_release_tag() {
	git -C "$repo" push -q --force "$remote" "refs/tags/$version"
}

expected_home="$work/expected-gnupg"
wrong_home="$work/wrong-gnupg"
expected_public_key="$work/expected-signing-key.asc"
wrong_public_key="$work/wrong-signing-key.asc"
create_signing_key "$expected_home" "Expected Release Signer <expected@example.invalid>" \
	"$expected_public_key" expected_fingerprint
create_signing_key "$wrong_home" "Wrong Release Signer <wrong@example.invalid>" \
	"$wrong_public_key" wrong_fingerprint

# Exercise the production verifier code with disposable fixture keys without
# making the production trust root overrideable through ambient variables.
verifier_fixture="$work/verifier"
mkdir -p "$verifier_fixture/scripts" "$verifier_fixture/release"
cp "$TAG_VERIFY_SOURCE" "$SIGNATURE_VERIFY_SOURCE" "$verifier_fixture/scripts/"
cp "$expected_public_key" "$verifier_fixture/release/signing-key.asc"
while IFS= read -r line || [ -n "$line" ]; do
	printf '%s\n' "${line//6184219C6670945D7174F2B0149F042FCC3D3AEC/$expected_fingerprint}"
done < "$ROOT/scripts/release-signing-policy.sh" \
	> "$verifier_fixture/scripts/release-signing-policy.sh"
chmod 755 "$verifier_fixture/scripts/verify-release-signature.sh" \
	"$verifier_fixture/scripts/verify-release-tag-target.sh"
TAG_VERIFY="$verifier_fixture/scripts/verify-release-tag-target.sh"
SIGNATURE_VERIFY="$verifier_fixture/scripts/verify-release-signature.sh"

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

setup_fixture
expect_fail "non-triggering dotted release suffix" "invalid expected release version" \
	"$snapshot" v99.0.0.rc1 "$release_sha"

grep -Fq 'fetch-depth: 2' "$WORKFLOW" \
	|| fail "release workflow does not fetch the qualified source parent"
grep -Fq 'RELEASE_OBJECT: ${{ github.sha }}' "$WORKFLOW" \
	|| fail "release workflow does not route the independent event object"
grep -Fq 'scripts/verify-release-history.sh "$dir" "$tag" "$RELEASE_OBJECT"' "$WORKFLOW" \
	|| fail "release workflow does not bind qualification to tag history"
grep -Fq 'scripts/verify-release-tag-target.sh origin "$tag" "$VERIFIED_RELEASE_COMMIT"' "$WORKFLOW" \
	|| fail "release workflow does not recheck the remote tag before publication"
grep -Fq 'scripts/verify-release-signature.sh detached \' "$WORKFLOW" \
	|| fail "release workflow does not verify the checksum signature"
grep -Fq 'cp -p -- "$dir"/*.hex "$dir/SHA256SUMS" "$dir/SHA256SUMS.asc" \' "$WORKFLOW" \
	|| fail "release workflow does not snapshot the verified checksum signature"
grep -Fq 'assets=( "$dir"/*.hex "$dir/SHA256SUMS" "$dir/SHA256SUMS.asc" \' "$WORKFLOW" \
	|| fail "release workflow does not publish the verified checksum signature"
checksum_verify_line=$(grep -nF 'scripts/verify-release-signature.sh detached \' "$WORKFLOW" | cut -d: -f1)
snapshot_line=$(grep -nF 'cp -p -- "$dir"/*.hex' "$WORKFLOW" | cut -d: -f1)
tag_verify_line=$(grep -nF 'scripts/verify-release-tag-target.sh origin' "$WORKFLOW" | cut -d: -f1)
publish_line=$(grep -nF 'gh release create "$tag"' "$WORKFLOW" | cut -d: -f1)
[ "$checksum_verify_line" -lt "$snapshot_line" ] \
	&& [ "$snapshot_line" -lt "$tag_verify_line" ] \
	&& [ "$tag_verify_line" -lt "$publish_line" ] \
	|| fail "release signature verification does not precede snapshot/publication"
locate_block=$(awk '/- name: Locate the committed release directory/ { in_block=1 }
	/# --- toolchains/ { in_block=0 }
	in_block { print }' "$WORKFLOW")
publish_block=$(awk '/- name: Publish GitHub Release/ { in_block=1 }
	in_block { print }' "$WORKFLOW")
[[ "$locate_block" == *'set -euo pipefail'* ]] \
	&& [[ "$locate_block" != *'verify-release-signature.sh detached'*'|| true'* ]] \
	|| fail "checksum-signature workflow verification is not fail-closed"
[[ "$publish_block" == *'set -euo pipefail'* ]] \
	&& [[ "$publish_block" != *'verify-release-tag-target.sh'*'|| true'* ]] \
	|| fail "tag-signature workflow verification is not fail-closed"
checks=$((checks + 1))

# The checked-in trust root must still verify both the first signed fixture used
# by this test and the rename verifier's latest historical baseline. This also
# catches an accidental key replacement independently of the disposable keys.
for historical_version in v0.9.5 v0.9.7; do
	"$PINNED_SIGNATURE_VERIFY" detached \
		"$ROOT/release/$historical_version/SHA256SUMS.asc" \
		"$ROOT/release/$historical_version/SHA256SUMS" >/dev/null \
		|| fail "pinned key did not verify the historical $historical_version checksums"
	checks=$((checks + 1))
done

# Git must not rewrite byte-exact artifacts even when the checkout policy would
# normally convert text to CRLF. This fixture deliberately includes an AVR HEX
# with CRLF in the index and PIC/checksum files with LF in the index.
autocrlf_checkout="$work/autocrlf-checkout"
mkdir -p "$autocrlf_checkout"
byte_exact_paths=(
	release/v0.9.5/bypass_cd4053.hex
	release/v0.9.5/bypass_cd4053_pic10f322.hex
	release/v0.9.5/SHA256SUMS
	release/v0.9.5/SHA256SUMS.asc
	test/pic10f320/expected_images.sha256
)
# These two are text rather than binary, but verification reads them by exact
# whole-line match -- the MANIFEST.md heading through `grep -Fxq`, each soak
# log's SOAK_RESULT record through string equality -- so a CRLF checkout makes
# `verify-release-qualification.sh` reject a correct release. They must survive
# the same conversion policy as the images, for a different reason.
line_matched_paths=(
	release/v0.9.5/MANIFEST.md
	release/v0.9.5/evidence/soak-avr_cd4053_t45.log
)
git -C "$ROOT" -c core.autocrlf=true checkout-index \
	--prefix="$autocrlf_checkout/" \
	-- "${byte_exact_paths[@]}" "${line_matched_paths[@]}" \
	|| fail "could not create autocrlf release-artifact checkout"
for path in "${byte_exact_paths[@]}" "${line_matched_paths[@]}"; do
	expected=$(git -C "$ROOT" cat-file blob ":$path" | sha256sum)
	expected=${expected%% *}
	actual=$(sha256sum "$autocrlf_checkout/$path")
	actual=${actual%% *}
	[ "$actual" = "$expected" ] \
		|| fail "autocrlf checkout changed byte-exact artifact: $path"
	checks=$((checks + 1))
done
"$PINNED_SIGNATURE_VERIFY" detached \
	"$autocrlf_checkout/release/v0.9.5/SHA256SUMS.asc" \
	"$autocrlf_checkout/release/v0.9.5/SHA256SUMS" >/dev/null \
	|| fail "autocrlf checkout invalidated the historical checksum signature"
checks=$((checks + 1))

# QUALIFICATION first appears in the next release, so assert its prospective
# path directly. Also pin the LF policy on each executable/source text class.
attribute=$(git -C "$ROOT" check-attr text -- release/v99.0.0/QUALIFICATION)
[ "$attribute" = "release/v99.0.0/QUALIFICATION: text: unset" ] \
	|| fail "QUALIFICATION is not marked byte-exact: $attribute"
checks=$((checks + 1))
for path in Makefile src/bypass_pure.c src/bypass_pure.h \
		test/avr/sim_attiny202.py test/test_release_history.sh \
		.github/workflows/release.yml test/pic/test_soak_pic.cc \
		release/v0.9.5/MANIFEST.md \
		release/v0.9.5/evidence/soak-avr_cd4053_t45.log; do
	attribute=$(git -C "$ROOT" check-attr text eol -- "$path")
	[ "$attribute" = "$path: text: set
$path: eol: lf" ] \
		|| fail "$path is not explicitly LF text: $attribute"
	checks=$((checks + 1))
done

# The allowlist above is what let MANIFEST.md and the evidence logs stay
# convertible while the images beside them were pinned, so assert the catch-all
# that now backstops it: a class nobody has named yet must still resolve to LF
# instead of inheriting the platform default.
unlisted=release/v99.0.0/evidence/unlisted.newext
attribute=$(git -C "$ROOT" check-attr text eol -- "$unlisted")
[ "$attribute" = "$unlisted: text: auto
$unlisted: eol: lf" ] \
	|| fail "unnamed file classes do not default to LF text: $attribute"
checks=$((checks + 1))

RELEASE_SIGNING_FINGERPRINT=$wrong_fingerprint \
RELEASE_SIGNING_PUBLIC_KEY=$wrong_public_key \
	"$PINNED_SIGNATURE_VERIFY" detached "$ROOT/release/v0.9.5/SHA256SUMS.asc" \
	"$ROOT/release/v0.9.5/SHA256SUMS" >/dev/null \
	|| fail "ambient environment replaced the production signing policy"
checks=$((checks + 1))

signed_file="$work/SHA256SUMS"
valid_signature="$work/SHA256SUMS.asc"
wrong_signature="$work/SHA256SUMS.wrong.asc"
printf '%064d  firmware.hex\n' 0 > "$signed_file"
gpg --batch --no-options --homedir "$expected_home" --local-user "$expected_fingerprint" \
	--armor --detach-sign --output "$valid_signature" "$signed_file" \
	|| fail "could not sign detached-signature fixture"
run_signature_verify detached "$valid_signature" "$signed_file" >/dev/null \
	|| fail "valid pinned-key checksum signature was rejected"
checks=$((checks + 1))

printf 'changed\n' >> "$signed_file"
expect_signature_fail "signature over different bytes" "signature is invalid" \
	detached "$valid_signature" "$signed_file"
printf '%064d  firmware.hex\n' 0 > "$signed_file"

gpg --batch --no-options --homedir "$wrong_home" --local-user "$wrong_fingerprint" \
	--armor --detach-sign --output "$wrong_signature" "$signed_file" \
	|| fail "could not create wrong-key signature fixture"
expect_signature_fail "signature from wrong key" "signature is invalid" \
	detached "$wrong_signature" "$signed_file"

empty_signature="$work/empty.asc"
: > "$empty_signature"
expect_signature_fail "empty detached signature" "missing, empty, or not a regular file" \
	detached "$empty_signature" "$signed_file"
signature_symlink="$work/signature-link.asc"
ln -s "$valid_signature" "$signature_symlink"
expect_signature_fail "symlink detached signature" "missing, empty, or not a regular file" \
	detached "$signature_symlink" "$signed_file"
expect_signature_fail "missing detached signature" "missing, empty, or not a regular file" \
	detached "$work/missing.asc" "$signed_file"

valid_status="$work/valid.status"
{
	printf '[GNUPG:] NEWSIG\n'
	printf '[GNUPG:] GOODSIG %s Expected Release Signer\n' "${expected_fingerprint:24}"
	printf '[GNUPG:] VALIDSIG %s 2026-07-28 1 0 4 0 22 10 00 %s\n' \
		"$expected_fingerprint" "$expected_fingerprint"
} > "$valid_status"
status_policy_accepts "$valid_status" \
	|| fail "valid GnuPG machine status was rejected"
checks=$((checks + 1))
for rejected_status in EXPSIG EXPKEYSIG REVKEYSIG KEYEXPIRED SIGEXPIRED KEYREVOKED; do
	status_fixture="$work/$rejected_status.status"
	{
		printf '[GNUPG:] NEWSIG\n'
		printf '[GNUPG:] GOODSIG %s Expected Release Signer\n' "${expected_fingerprint:24}"
		printf '[GNUPG:] %s %s rejected-status fixture\n' \
			"$rejected_status" "${expected_fingerprint:24}"
		printf '[GNUPG:] VALIDSIG %s 2026-07-28 1 0 4 0 22 10 00 %s\n' \
			"$expected_fingerprint" "$expected_fingerprint"
	} > "$status_fixture"
	if status_policy_accepts "$status_fixture"; then
		fail "$rejected_status GnuPG status was accepted"
	fi
	checks=$((checks + 1))
done
for status_record in NEWSIG GOODSIG VALIDSIG; do
	missing_status="$work/missing-$status_record.status"
	awk -v record="$status_record" \
		'!($1 == "[GNUPG:]" && $2 == record)' "$valid_status" > "$missing_status"
	if status_policy_accepts "$missing_status"; then
		fail "missing $status_record GnuPG status was accepted"
	fi
	checks=$((checks + 1))

	duplicate_status="$work/duplicate-$status_record.status"
	cp "$valid_status" "$duplicate_status"
	awk -v record="$status_record" \
		'$1 == "[GNUPG:]" && $2 == record { print }' "$valid_status" \
		>> "$duplicate_status"
	if status_policy_accepts "$duplicate_status"; then
		fail "duplicate $status_record GnuPG status was accepted"
	fi
	checks=$((checks + 1))
done

# A local bare remote makes signed-tag enforcement deterministic and network-free.
setup_fixture
remote="$work/remote.git"
git init -q --bare "$remote"
git -C "$repo" tag "$version" "$release_sha"
push_release_tag
expect_tag_fail "remote lightweight release tag" "must be one annotated tag"

git -C "$repo" tag -fa "$version" -m "unsigned release" "$release_sha" >/dev/null
push_release_tag
expect_tag_fail "unsigned annotated release tag" "required signature"

GNUPGHOME="$wrong_home" git -C "$repo" -c user.signingkey="$wrong_fingerprint" \
	-c gpg.format=openpgp -c gpg.openpgp.program=gpg \
	tag -sf "$version" -m "wrong-key release" "$release_sha" >/dev/null
push_release_tag
expect_tag_fail "wrong-key signed release tag" "required signature"

GNUPGHOME="$expected_home" git -C "$repo" -c user.signingkey="$expected_fingerprint" \
	-c gpg.format=openpgp -c gpg.openpgp.program=gpg \
	tag -sf "$version" -m "signed release" "$release_sha" >/dev/null
push_release_tag
run_tag_verify "$remote" "$version" "$release_sha" >/dev/null \
	|| fail "valid pinned-key signed release tag was rejected"
checks=$((checks + 1))

other_version=v99.0.1
GNUPGHOME="$expected_home" git -C "$repo" -c user.signingkey="$expected_fingerprint" \
	-c gpg.format=openpgp -c gpg.openpgp.program=gpg \
	tag -sf "$other_version" -m "different signed release name" "$release_sha" >/dev/null
aliased_tag_object=$(git -C "$repo" rev-parse "refs/tags/$other_version")
git -C "$repo" update-ref "refs/tags/$version" "$aliased_tag_object"
push_release_tag
expect_tag_fail "differently named signed tag object" "signed tag object named $other_version"

git -C "$repo" tag -fa "$version" -m "unsigned replacement" "$release_sha" >/dev/null
push_release_tag
expect_tag_fail "same-target unsigned tag replacement" "required signature"

GNUPGHOME="$expected_home" git -C "$repo" -c user.signingkey="$expected_fingerprint" \
	-c gpg.format=openpgp -c gpg.openpgp.program=gpg \
	tag -sf "$version" -m "moved signed release" "$source_sha" >/dev/null
push_release_tag
expect_tag_fail "moved signed release tag" "remote tag $version moved"

if output=$(run_tag_verify "$remote" v99.0.1 "$release_sha" 2>&1); then
	fail "missing remote release tag was accepted"
fi
[[ "$output" == *"missing or ambiguous"* ]] \
	|| fail "missing remote tag failed for the wrong reason: $output"
checks=$((checks + 1))

if output=$(run_tag_verify "$remote" v99.0.0.rc1 "$release_sha" 2>&1); then
	fail "remote verifier accepted a tag name the release workflow does not trigger"
fi
[[ "$output" == *"invalid release tag"* ]] \
	|| fail "invalid remote tag name failed for the wrong reason: $output"
checks=$((checks + 1))

printf 'release history validation: %d checks, 0 failures\n' "$checks"
