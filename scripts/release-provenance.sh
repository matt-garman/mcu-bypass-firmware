#!/usr/bin/env bash

# Recheck the source identity captured before a long release run. This file is
# sourced at startup so the running script retains the original check logic even
# if the worktree is edited while validation is in progress.
release_source_is_unchanged() {
	local expected_sha=$1
	local permit_dirty=$2
	local current_sha status

	case "$permit_dirty" in
		0|1) ;;
		*)
			printf 'FATAL: invalid release provenance dirty policy: %s\n' \
				"$permit_dirty" >&2
			return 1
			;;
	esac

	current_sha=$(git rev-parse --verify HEAD 2>/dev/null) || {
		printf 'FATAL: cannot resolve HEAD during final release provenance check\n' >&2
		return 1
	}
	if [ "$current_sha" != "$expected_sha" ]; then
		printf 'FATAL: source HEAD changed during release (expected %s, found %s)\n' \
			"$expected_sha" "$current_sha" >&2
		return 1
	fi

	status=$(git status --porcelain --untracked-files=all) || {
		printf 'FATAL: cannot inspect the worktree during final release provenance check\n' >&2
		return 1
	}
	if [ -n "$status" ]; then
		if [ "$permit_dirty" -eq 1 ]; then
			printf 'WARN: working tree is dirty at final provenance check; source SHA does not capture uncommitted changes.\n' >&2
			return 0
		fi
		git status --short >&2 || true
		printf 'FATAL: working tree is dirty at final provenance check; refusing to stage release artifacts\n' >&2
		return 1
	fi
}
