#!/usr/bin/env bash

# Fail-closed provenance helpers for the release orchestrator. This file is
# sourced at startup so the running script retains the original check logic even
# if the worktree is edited while validation is in progress.
release_tool_version_line() {
	if [ "$#" -ne 2 ]; then
		printf 'FATAL: release_tool_version_line requires a label and executable\n' >&2
		return 2
	fi
	local label=$1
	local tool=$2
	local output status first_line

	if output=$("$tool" --version 2>&1); then
		status=0
	else
		status=$?
	fi
	if [ "$status" -ne 0 ]; then
		printf 'FATAL: cannot identify %s: %s --version exited %d\n' \
			"$label" "$tool" "$status" >&2
		[ -z "$output" ] || printf '%s\n' "$output" >&2
		return 1
	fi

	first_line=${output%%$'\n'*}
	if [ -z "${first_line//[[:space:]]/}" ]; then
		printf 'FATAL: cannot identify %s: %s --version returned no version line\n' \
			"$label" "$tool" >&2
		return 1
	fi
	printf '%s\n' "$first_line"
}

release_output_path_is_safe() {
	if [ "$#" -ne 3 ]; then
		printf 'FATAL: release_output_path_is_safe requires repo root, output path, and release mode\n' >&2
		return 2
	fi
	local repo_root=$1
	local output_dir=$2
	local release_mode=$3
	local release_root output_abs

	case "$release_mode" in
		production) return 0 ;;
		dry-run) ;;
		*)
			printf 'FATAL: invalid release output mode: %s\n' "$release_mode" >&2
			return 1
			;;
	esac

	command -v realpath >/dev/null 2>&1 || {
		printf 'FATAL: realpath is required to validate a dry-run output path\n' >&2
		return 1
	}
	release_root=$(realpath -m -- "$repo_root/release") || {
		printf 'FATAL: cannot resolve the repository release directory\n' >&2
		return 1
	}
	case "$output_dir" in
		/*) ;;
		*) output_dir="$repo_root/$output_dir" ;;
	esac
	output_abs=$(realpath -m -- "$output_dir") || {
		printf 'FATAL: cannot resolve dry-run output path: %s\n' "$output_dir" >&2
		return 1
	}

	case "$output_abs" in
		"$release_root"|"$release_root"/*)
			printf 'FATAL: dry-run output must not be staged under the repository release tree: %s\n' \
				"$output_abs" >&2
			return 1
			;;
	esac
}

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
