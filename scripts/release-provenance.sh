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

# Exact-equality test for an image-defining compiler's version pin.
#
# The predecessor of this check used shell substring patterns (*7.3.0*,
# *V3.10*), which accept any banner CONTAINING the pin. avr-gcc 17.3.0 passed
# the 7.3.0 check and XC8 V3.100 passed the V3.10 check, as would 7.3.0.1 or
# V13.10. Released image bytes are gated on the exact compiler, so a check that
# accepts a neighbouring version is worse than no check: it reports an
# enforcement the release does not actually have.
#
# $1 is the compiler's own first version line; $2 is the pinned version WITHOUT
# any V/v prefix ("7.3.0", "3.10"). Succeeds only when the banner yields exactly
# one version-shaped token and that token equals the pin.
#
# TOKENIZATION. Parenthesised segments are removed first: that is where GCC
# writes its packaging blob ("avr-gcc (Ubuntu 7.3.0-16ubuntu3) 7.3.0"), and it
# must not be able to masquerade as the compiler version or make an otherwise
# exact banner ambiguous. What remains is split on whitespace ALONE, so a
# version token keeps whatever was attached to it and is compared whole:
# "7.3.0.1" is one token rather than a "7.3.0" prefix, and "V3.100" is one token
# rather than "V3.10" plus a stray digit. A candidate is any token that opens
# like a dotted decimal version, with the optional V/v that XC8 writes.
#
# Zero candidates (prose-only or malformed output) and two or more (ambiguous)
# both fail, so this cannot silently pick a version out of an unrecognized
# banner form. Rejecting an unfamiliar-but-valid banner is a loud failure whose
# diagnostic names what it saw; accepting a drifted one ships wrong bytes.
release_pinned_version_matches() {
	if [ "$#" -ne 2 ]; then
		printf 'FATAL: release_pinned_version_matches requires a version line and a pinned version\n' >&2
		return 2
	fi
	local banner=$1 expected=$2
	local word token found=0 matched=0
	local -a words

	# Drop parenthesised segments, innermost first; each pass removes at least
	# the two delimiters, so this terminates. An unbalanced parenthesis matches
	# nothing and stays attached to its word, which then cannot open like a
	# version and is simply not a candidate.
	while [[ "$banner" =~ ^(.*)\([^()]*\)(.*)$ ]]; do
		banner="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
	done
	read -r -a words <<<"$banner"
	for word in ${words[@]+"${words[@]}"}; do
		[[ "$word" =~ ^[Vv]?[0-9]+\. ]] || continue
		found=$((found + 1))
		token=${word#[Vv]}
		[ "$token" = "$expected" ] && matched=$((matched + 1))
	done
	[ "$found" -eq 1 ] && [ "$matched" -eq 1 ]
}

release_require_main_branch() {
	if [ "$#" -ne 1 ]; then
		printf 'FATAL: release_require_main_branch requires the repository root\n' >&2
		return 2
	fi
	local repo_root=$1 branch_ref

	branch_ref=$(git -C "$repo_root" symbolic-ref --quiet HEAD) || {
		printf 'FATAL: production release requires the main branch; HEAD is detached or unreadable\n' >&2
		return 1
	}
	if [ "$branch_ref" != refs/heads/main ]; then
		printf 'FATAL: production release requires refs/heads/main; checked out %s\n' \
			"$branch_ref" >&2
		return 1
	fi
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

# Hash classic-AVR HEX files by basename so build-tree paths compare directly
# with their staged counterparts. The final HEX files are regenerated from the
# validated ELFs after all gates and soaks, making this the byte-level handoff
# from validated executable to release artifact.
release_hash_classic_avr_images() {
	local image result hash
	[ "$#" -gt 0 ] || {
		printf 'FATAL: no classic AVR images supplied for release hashing\n' >&2
		return 2
	}
	for image in "$@"; do
		if [ ! -f "$image" ] || [ -L "$image" ] || [ ! -s "$image" ]; then
			printf 'FATAL: classic AVR image missing, empty, or not regular: %s\n' \
				"$image" >&2
			return 1
		fi
		result=$(sha256sum -- "$image") || return 1
		hash=${result%% *}
		printf '%s  %s\n' "$hash" "${image##*/}"
	done
}

# Copy the complete classic-AVR set, construct the destination paths only after
# each copy, then re-read every staged byte. This closes both sides of the copy
# boundary before SHA256SUMS can attest to a substituted destination.
release_stage_classic_avr_images() {
	[ "$#" -gt 2 ] || {
		printf 'FATAL: release_stage_classic_avr_images requires output, hashes, and images\n' >&2
		return 2
	}
	local output_dir=$1 expected_hashes=$2 image staged_hashes
	shift 2
	local -a staged_images=()
	for image in "$@"; do
		cp -p -- "$image" "$output_dir/" || return 1
		staged_images+=("$output_dir/${image##*/}")
	done
	staged_hashes=$(release_hash_classic_avr_images "${staged_images[@]}") \
		|| return 1
	[ "$staged_hashes" = "$expected_hashes" ]
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
