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
	if [ "$#" -ne 4 ]; then
		printf 'FATAL: release_output_path_is_safe requires repo root, output path, release mode, and version\n' >&2
		return 2
	fi
	local repo_root=$1
	local output_dir=$2
	local release_mode=$3
	local version=$4
	local release_root output_abs expected_output

	case "$release_mode" in
		production|dry-run) ;;
		*)
			printf 'FATAL: invalid release output mode: %s\n' "$release_mode" >&2
			return 1
			;;
	esac

	command -v realpath >/dev/null 2>&1 || {
		printf 'FATAL: realpath is required to validate a release output path\n' >&2
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
		printf 'FATAL: cannot resolve release output path: %s\n' "$output_dir" >&2
		return 1
	}
	expected_output="$release_root/$version"

	if [ "$release_mode" = production ]; then
		if [ "$output_abs" != "$expected_output" ]; then
			printf 'FATAL: production output must be exactly %s (found %s)\n' \
				"$expected_output" "$output_abs" >&2
			return 1
		fi
		return 0
	fi

	case "$output_abs" in
		"$release_root"|"$release_root"/*)
			printf 'FATAL: dry-run output must not be staged under the repository release tree: %s\n' \
				"$output_abs" >&2
			return 1
			;;
	esac
}

release_terminate_workers() {
	local pid running
	local -a pids=("$@")
	local -a active=()

	for pid in "${pids[@]}"; do
		case "$pid" in
			''|*[!0-9]*)
				printf 'FATAL: invalid release worker PID: %s\n' "$pid" >&2
				return 2
				;;
		esac
	done
	[ "${#pids[@]}" -gt 0 ] || return 0

	# Consult Bash's live job table before signaling. Completed children may have
	# been reaped asynchronously and their numeric PIDs reused during a 24-hour
	# run; only a PID that is both tracked and still our running job is safe.
	while IFS= read -r running; do
		for pid in "${pids[@]}"; do
			[ "$running" != "$pid" ] || active+=("$pid")
		done
	done < <(jobs -pr)
	for pid in "${active[@]}"; do
		# Every soak is launched under setsid with PID == process-group ID.
		kill -TERM -- "-$pid" 2>/dev/null || true
	done
	sleep 1
	# Keep the initial group set for KILL. A cooperative leader can exit on TERM
	# while one of its descendants ignores the signal; that descendant preserves
	# the original process group even after Bash drops the leader from jobs -pr.
	for pid in "${active[@]}"; do
		kill -KILL -- "-$pid" 2>/dev/null || true
	done
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
}

release_jobs_cap() {
	if [ "$#" -ne 2 ]; then
		printf 'FATAL: release_jobs_cap requires requested jobs and combination count\n' >&2
		return 2
	fi
	local requested=$1
	local combinations=$2

	[[ "$combinations" =~ ^[1-9][0-9]*$ ]] || {
		printf 'FATAL: invalid release combination count: %s\n' "$combinations" >&2
		return 2
	}
	if [ -z "$requested" ]; then
		printf '%s\n' "$combinations"
		return 0
	fi
	[[ "$requested" =~ ^[1-9][0-9]*$ ]] || {
		printf 'FATAL: invalid requested release jobs: %s\n' "$requested" >&2
		return 2
	}
	if [ "${#requested}" -gt "${#combinations}" ] \
			|| { [ "${#requested}" -eq "${#combinations}" ] \
				&& [[ "$requested" > "$combinations" ]]; }; then
		printf '%s\n' "$combinations"
	else
		printf '%s\n' "$requested"
	fi
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
