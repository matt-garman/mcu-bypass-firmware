#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FETCH="$ROOT/scripts/fetch_yasimavr.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-fetch-yasimavr.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_fail() {
	local label=$1 expected=$2 output
	shift 2
	if output=$("$@" 2>&1); then
		fail "$label: unsafe request was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

valid_stamp='old-version 0000000000000000000000000000000000000000000000000000000000000000 1111111111111111111111111111111111111111111111111111111111111111'

# Argument and path rejection happens before any tool or network checks.
expect_fail "extra argument" "usage:" "$FETCH" "$work/new-venv" extra
[ ! -e "$work/new-venv" ] || fail "extra-argument check created its destination"
expect_fail "empty destination" "must not be empty" "$FETCH" ''

nonvenv="$work/existing-non-venv"
mkdir "$nonvenv"
printf 'preserve me\n' > "$nonvenv/sentinel"
expect_fail "unstamped existing directory" "without a valid .yasimavr.stamp" \
	"$FETCH" "$nonvenv"
[ "$(<"$nonvenv/sentinel")" = 'preserve me' ] \
	|| fail "unstamped-directory sentinel was changed"
checks=$((checks + 1))

printf 'not a valid ownership stamp\n' > "$nonvenv/.yasimavr.stamp"
expect_fail "malformed ownership stamp" "without a valid .yasimavr.stamp" \
	"$FETCH" "$nonvenv"
[ "$(<"$nonvenv/sentinel")" = 'preserve me' ] \
	|| fail "malformed-stamp sentinel was changed"
checks=$((checks + 1))

rm "$nonvenv/.yasimavr.stamp"
printf '%s' "$valid_stamp" > "$work/stamp-target"
ln -s "$work/stamp-target" "$nonvenv/.yasimavr.stamp"
expect_fail "symlink ownership stamp" "without a valid .yasimavr.stamp" \
	"$FETCH" "$nonvenv"
[ "$(<"$nonvenv/sentinel")" = 'preserve me' ] \
	|| fail "symlink-stamp sentinel was changed"
checks=$((checks + 1))

symlink_target="$work/symlink-target"
mkdir "$symlink_target"
printf 'preserve target\n' > "$symlink_target/sentinel"
ln -s "$symlink_target" "$work/venv-link"
expect_fail "symlink destination" "must not be a symlink" \
	"$FETCH" "$work/venv-link"
expect_fail "trailing-slash symlink destination" "must not be a symlink" \
	"$FETCH" "$work/venv-link/"
[ "$(<"$symlink_target/sentinel")" = 'preserve target' ] \
	|| fail "symlink-destination sentinel was changed"
checks=$((checks + 1))

printf 'ordinary file\n' > "$work/not-a-directory"
expect_fail "file destination" "is not a directory" \
	"$FETCH" "$work/not-a-directory"
expect_fail "missing parent" "parent does not exist" \
	"$FETCH" "$work/missing-parent/venv"

# Use a disposable script copy to prove canonicalization rejects its own repo
# root without ever putting the real checkout at risk.
fixture="$work/repo-fixture"
mkdir -p "$fixture/scripts"
cp "$FETCH" "$fixture/scripts/fetch_yasimavr.sh"
chmod +x "$fixture/scripts/fetch_yasimavr.sh"
printf 'preserve fixture\n' > "$fixture/sentinel"
expect_fail "canonical repository root" "repository root as VENV_DIR" \
	"$fixture/scripts/fetch_yasimavr.sh" "$fixture/scripts/.."
ln -s "$fixture" "$work/repo-fixture-link"
expect_fail "physical repository root through symlink" "repository root as VENV_DIR" \
	"$work/repo-fixture-link/scripts/fetch_yasimavr.sh" "$fixture"
double_slash_fixture="//${fixture#/}"
expect_fail "double-slash repository alias" "repository root as VENV_DIR" \
	"$double_slash_fixture/scripts/fetch_yasimavr.sh" "$fixture"
[ "$(<"$fixture/sentinel")" = 'preserve fixture' ] \
	|| fail "repository-root sentinel was changed"
checks=$((checks + 1))
grep -Fq '[ "$VENV" != / ] || die "refusing to use the filesystem root as VENV_DIR"' \
	"$FETCH" || fail "filesystem-root guard is missing"
grep -Fxq 'third_party/yasimavr/.venv.old.*/' "$ROOT/.gitignore" \
	|| fail "default-path rollback backups are not ignored"
checks=$((checks + 1))

# Offline fake tools drive a complete build, verification and rename without
# downloading or executing third-party code.
fakebin="$work/fakebin"
mkdir "$fakebin"
real_mv=$(command -v mv) || fail "mv is required"
cat > "$fakebin/c++" <<'EOF'
#!/bin/sh
set -eu
source_text=$(cat)
case "$source_text" in
	*'<span>'*) [ "${FAKE_CXX20_FAIL:-0}" -eq 0 ] || exit 41 ;;
	*'<libelf.h>'*) [ "${FAKE_LIBELF_FAIL:-0}" -eq 0 ] || exit 42 ;;
esac
exit 0
EOF
cat > "$fakebin/curl" <<'EOF'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then
		shift
		: > "$1"
		exit 0
	fi
	shift
done
exit 2
EOF
cat > "$fakebin/tar" <<'EOF'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
	if [ "$1" = -C ]; then
		shift
		mkdir -p "$1/yasimavr-${YASIMAVR_VER:-0.1.6}"
		exit 0
	fi
	shift
done
exit 2
EOF
cat > "$fakebin/patch" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 0
EOF
cat > "$fakebin/mv" <<'EOF'
#!/bin/sh
set -eu
source_path=
destination_path=
for argument in "$@"; do
	source_path=$destination_path
	destination_path=$argument
done
case "$source_path" in
	*/.*.build.*)
		if [ "${FAKE_MV_SIGNAL_INSTALL_DEST:-}" = "$destination_path" ]; then
			kill -TERM "$PPID"
			exit 143
		fi
		if [ "${FAKE_MV_FAIL_INSTALL_DEST:-}" = "$destination_path" ]; then
			exit 31
		fi
		if [ "${FAKE_MV_RACE_DEST:-}" = "$destination_path" ]; then
			mkdir -p "$destination_path"
			[ -z "${FAKE_MV_RACE_MARKER:-}" ] \
				|| printf 'late unrelated directory\n' > "$FAKE_MV_RACE_MARKER"
		fi
		;;
esac
exec "$REAL_MV" "$@"
EOF
cat > "$work/venv-python" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = - ]; then
	cat >/dev/null
	[ "${FAKE_VERIFY_FAIL:-0}" -eq 0 ] || exit 24
	exit 0
fi
if [ "${FAKE_PIP_INSTALL_FAIL:-0}" -eq 1 ] \
		&& [ "${1:-}" = -m ] && [ "${2:-}" = pip ] \
		&& [ "${3:-}" = install ]; then
	exit 23
fi
if [ "${1:-}" = -m ] && [ "${2:-}" = pip ] \
		&& [ "${3:-}" = install ] && [ -n "${FAKE_PIP_LOG:-}" ]; then
	printf '%s\n' "$*" >> "$FAKE_PIP_LOG"
fi
if [ "${1:-}" = -m ] && [ "${2:-}" = pip ] \
		&& [ "${3:-}" = install ] && [ "${FAKE_REQUIRE_CXX:-0}" -eq 1 ] \
		&& [ -z "${CXX:-}" ]; then
	exit 25
fi
exit 0
EOF
cat > "$fakebin/python3" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = - ]; then
	cat >/dev/null
	exit 0
fi
if [ "${1:-}" = -c ]; then
	[ "${FAKE_PYTHON_PLATFORM_FAIL:-0}" -eq 0 ] || exit 40
	exit 0
fi
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ]; then
	shift 2
	[ "${1:-}" != --without-pip ] || shift
	destination=$1
	mkdir -p "$destination/bin"
	cp "$FAKE_VENV_PY_TEMPLATE" "$destination/bin/python"
	chmod +x "$destination/bin/python"
	exit 0
fi
exit 2
EOF
chmod +x "$fakebin"/* "$work/venv-python"

empty_sha=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
run_fake() {
	env PATH="$fakebin:$PATH" \
		FAKE_VENV_PY_TEMPLATE="$work/venv-python" \
		FAKE_PIP_LOG="$work/pip-install.log" \
		FAKE_REQUIRE_CXX=1 \
		REAL_MV="$real_mv" \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$@"
}

expect_fail "unsupported Python platform" "lock supports standard 64-bit CPython" \
	env PATH="$fakebin:$PATH" FAKE_PYTHON_PLATFORM_FAIL=1 \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$work/python-platform-venv"
expect_fail "missing C++20 feature" "does not support C++20" \
	env PATH="$fakebin:$PATH" FAKE_CXX20_FAIL=1 \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$work/cxx20-venv"
expect_fail "missing libelf development files" "libelf headers/library not usable" \
	env PATH="$fakebin:$PATH" FAKE_LIBELF_FAIL=1 \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$work/libelf-venv"

space_parent="$work/path with spaces"
mkdir "$space_parent"
new_venv="$space_parent/new-venv"
output=$(run_fake "$new_venv" 2>&1) \
	|| fail "offline fresh build failed: $output"
[[ "$output" == *"YASIMAVR_VENV=$new_venv"* ]] \
	|| fail "fresh build did not report its canonical destination: $output"
[ -x "$new_venv/bin/python" ] && [ -f "$new_venv/.yasimavr.stamp" ] \
	|| fail "fresh build did not install a complete stamped venv"
grep -Fq -- '--require-hashes --only-binary=:all: -r ' "$work/pip-install.log" \
	|| fail "yasimavr dependencies were not installed from the hash lock"
grep -Fq -- '--no-index --no-build-isolation --no-deps ' "$work/pip-install.log" \
	|| fail "yasimavr source build could still resolve external dependencies"
! grep -Fq 'get-pip.py' "$FETCH" \
	|| fail "yasimavr fetcher still contains the unhashed get-pip fallback"
checks=$((checks + 1))

printf 'cached tree\n' > "$new_venv/cached-sentinel"
output=$(run_fake "$new_venv" 2>&1) \
	|| fail "cached venv check failed: $output"
[[ "$output" == *"nothing to do"* ]] && [ -f "$new_venv/cached-sentinel" ] \
	|| fail "matching stamped venv was rebuilt instead of reused"
checks=$((checks + 1))

stale_venv="$work/stale-venv"
mkdir "$stale_venv"
printf '%s' "$valid_stamp" > "$stale_venv/.yasimavr.stamp"
printf 'replace only this owned tree\n' > "$stale_venv/old-sentinel"
run_fake "$stale_venv" >/dev/null 2>&1 \
	|| fail "stale stamped venv was not replaceable"
[ -x "$stale_venv/bin/python" ] && [ ! -e "$stale_venv/old-sentinel" ] \
	|| fail "stale stamped venv was not replaced by the verified tree"
mapfile -t stale_backups < <(compgen -G "$work/.stale-venv.old.*")
[ "${#stale_backups[@]}" -eq 1 ] \
	&& [ "$(<"${stale_backups[0]}/old-sentinel")" = 'replace only this owned tree' ] \
	|| fail "replaced stamped venv was not retained as one rollback backup"
checks=$((checks + 1))

failed_venv="$work/failed-rebuild-venv"
mkdir "$failed_venv"
printf '%s' "$valid_stamp" > "$failed_venv/.yasimavr.stamp"
printf 'must survive failed rebuild\n' > "$failed_venv/sentinel"
expect_fail "failed rebuild" "installation of hash-locked yasimavr dependencies failed" \
	env PATH="$fakebin:$PATH" FAKE_VENV_PY_TEMPLATE="$work/venv-python" \
		REAL_MV="$real_mv" FAKE_PIP_INSTALL_FAIL=1 \
		YASIMAVR_SDIST_SHA256="$empty_sha" \
		"$FETCH" "$failed_venv"
[ "$(<"$failed_venv/sentinel")" = 'must survive failed rebuild' ] \
	|| fail "failed rebuild changed the previous stamped venv"
[ "$(<"$failed_venv/.yasimavr.stamp")" = "$valid_stamp" ] \
	|| fail "failed rebuild changed the previous ownership stamp"
checks=$((checks + 1))

verify_venv="$work/failed-verification-venv"
mkdir "$verify_venv"
printf '%s' "$valid_stamp" > "$verify_venv/.yasimavr.stamp"
printf 'must survive failed verification\n' > "$verify_venv/sentinel"
expect_fail "failed post-build verification" "post-build verification failed" \
	env PATH="$fakebin:$PATH" FAKE_VENV_PY_TEMPLATE="$work/venv-python" \
		REAL_MV="$real_mv" FAKE_VERIFY_FAIL=1 \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$verify_venv"
[ "$(<"$verify_venv/sentinel")" = 'must survive failed verification' ] \
	|| fail "failed verification changed the previous stamped venv"
checks=$((checks + 1))

rollback_venv="$work/rollback-venv"
mkdir "$rollback_venv"
printf '%s' "$valid_stamp" > "$rollback_venv/.yasimavr.stamp"
printf 'must survive failed rename\n' > "$rollback_venv/sentinel"
expect_fail "failed install rename" "could not install the verified VENV_DIR" \
	env PATH="$fakebin:$PATH" FAKE_VENV_PY_TEMPLATE="$work/venv-python" \
		REAL_MV="$real_mv" FAKE_MV_FAIL_INSTALL_DEST="$rollback_venv" \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$rollback_venv"
[ "$(<"$rollback_venv/sentinel")" = 'must survive failed rename' ] \
	|| fail "failed install rename did not restore the previous stamped venv"
checks=$((checks + 1))

signal_venv="$work/signal-rollback-venv"
mkdir "$signal_venv"
printf '%s' "$valid_stamp" > "$signal_venv/.yasimavr.stamp"
printf 'must survive interrupted rename\n' > "$signal_venv/sentinel"
if env PATH="$fakebin:$PATH" FAKE_VENV_PY_TEMPLATE="$work/venv-python" \
		REAL_MV="$real_mv" FAKE_MV_SIGNAL_INSTALL_DEST="$signal_venv" \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$signal_venv" \
		>/dev/null 2>&1; then
	fail "signal during install rename was accepted"
fi
[ "$(<"$signal_venv/sentinel")" = 'must survive interrupted rename' ] \
	|| fail "signal cleanup did not restore the previous stamped venv"
checks=$((checks + 1))

race_venv="$work/late-directory-venv"
race_marker="$work/late-directory-created"
expect_fail "destination appeared before install" "could not install the verified VENV_DIR" \
	env PATH="$fakebin:$PATH" FAKE_VENV_PY_TEMPLATE="$work/venv-python" \
		REAL_MV="$real_mv" FAKE_MV_RACE_DEST="$race_venv" \
		FAKE_MV_RACE_MARKER="$race_marker" \
		YASIMAVR_SDIST_SHA256="$empty_sha" "$FETCH" "$race_venv"
[ "$(<"$race_marker")" = 'late unrelated directory' ] && [ -d "$race_venv" ] \
	|| fail "empty late destination was not retained"
[ ! -e "$race_venv/bin/python" ] && [ ! -e "$race_venv/.yasimavr.stamp" ] \
	|| fail "verified build was nested into a late unrelated destination"
checks=$((checks + 1))

for leftover in "$space_parent"/.new-venv.build.* \
		"$work"/.failed-rebuild-venv.* "$work"/.failed-verification-venv.* \
		"$work"/.rollback-venv.* "$work"/.signal-rollback-venv.* \
		"$work"/.late-directory-venv.*; do
	[ ! -e "$leftover" ] || fail "temporary sibling survived cleanup: $leftover"
done
checks=$((checks + 1))

printf 'yasimavr fetch safety: %d checks, 0 failures\n' "$checks"
