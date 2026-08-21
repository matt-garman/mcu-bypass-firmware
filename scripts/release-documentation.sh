#!/usr/bin/env bash
# Release metadata helpers. Renderers write only document bytes to stdout; the
# validator reads bounded source documentation without modifying it.

_release_documentation_error() {
	printf 'release documentation: %s\n' "$*" >&2
	return 1
}

_release_current_block() {
	[ "$#" -eq 1 ] || return 2
	awk '
		$0 == "<!-- current-release:start -->" {
			starts++
			if (starts != 1 || current) bad=1
			current=1
			next
		}
		$0 == "<!-- current-release:end -->" {
			ends++
			if (ends != 1 || !current) bad=1
			current=0
			next
		}
		current { print }
		END { exit !(starts == 1 && ends == 1 && !current && !bad) }
	' "$1"
}

release_validate_current_documentation() {
	[ "$#" -eq 4 ] || return 2
	local repo_root=$1 version=$2 image_count=$3 soak_count=$4
	local release_number=${version#v} changelog="$repo_root/CHANGELOG.md"
	local document block contract_line section_count previous_version link_count
	local -a current_documents=(
		"$repo_root/release/README.md"
		"$repo_root/TODO.md"
		"$repo_root/docs/pic10f320_special_case.md"
		"$repo_root/docs/pic10f320_validation.md"
	)

	[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "requested version is not vX.Y.Z: $version" || return
	[[ "$image_count" =~ ^[1-9][0-9]*$ && "$soak_count" =~ ^[1-9][0-9]*$ ]] \
		|| _release_documentation_error "canonical image/soak counts are invalid" || return
	[ -f "$changelog" ] && [ -s "$changelog" ] && [ ! -L "$changelog" ] \
		|| _release_documentation_error "CHANGELOG.md is not a regular nonempty file" || return

	section_count=$(awk -v release="$release_number" '
		/^## \[[^]]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			if (name == release) count++
		}
		END { print count + 0 }
	' "$changelog") || return
	[ "$section_count" -eq 1 ] \
		|| _release_documentation_error "CHANGELOG.md must contain one dated [$release_number] section" || return
	if ! awk -v release="$release_number" '
		$0 == "## [Unreleased]" {
			unreleased++
			waiting=1
			next
		}
		/^## \[[^]]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			if (waiting) {
				first_after_unreleased=name
				waiting=0
			}
			current=(name == release)
			if (current) requested++
			next
		}
		current && /^### (Added|Changed|Deprecated|Removed|Fixed|Security)$/ { categories++ }
		current && /^- / { entries++ }
		END {
			exit !(unreleased == 1 && first_after_unreleased == release \
				&& requested == 1 && categories > 0 && entries > 0)
		}
	' "$changelog"; then
		_release_documentation_error "CHANGELOG.md must put one nonempty dated [$release_number] section immediately after one Unreleased heading" || return
	fi

	previous_version=$(awk -v heading="## [$release_number] - " '
		index($0, heading) == 1 { current=1; next }
		current && /^## \[[^]]+\] - / {
			name=$0
			sub(/^## \[/, "", name)
			sub(/\] - .*/, "", name)
			print "v" name
			exit
		}
	' "$changelog") || return
	[[ "$previous_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
		|| _release_documentation_error "CHANGELOG.md [$release_number] section has no preceding-release section" || return
	link_count=$(grep -Fxc "[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/$version...HEAD" "$changelog" || true)
	[ "$link_count" -eq 1 ] \
		|| _release_documentation_error "CHANGELOG.md has no exact $version...HEAD Unreleased link" || return
	link_count=$(grep -Fxc "[$release_number]: https://github.com/matt-garman/mcu-bypass-firmware/compare/$previous_version...$version" "$changelog" || true)
	[ "$link_count" -eq 1 ] \
		|| _release_documentation_error "CHANGELOG.md has no exact $previous_version...$version release link" || return

	contract_line="**Current release contract:** \`$version\`; seven release parts; $image_count images; $soak_count soak combinations; six modular targets; four shell source files."
	for document in "${current_documents[@]}"; do
		[ -f "$document" ] && [ -s "$document" ] && [ ! -L "$document" ] \
			|| _release_documentation_error "designated current-release document is not a regular nonempty file: ${document#$repo_root/}" || return
		if ! block=$(_release_current_block "$document"); then
			_release_documentation_error "${document#$repo_root/} must contain one bounded current-release block" || return
		fi
		link_count=$(awk '{ sub(/^>[[:space:]]*/, ""); print }' <<<"$block" \
			| grep -Fxc "$contract_line" || true)
		[ "$link_count" -eq 1 ] \
			|| _release_documentation_error "${document#$repo_root/} must contain the exact current release contract: $contract_line" || return
	done
}

# Reject a release cut from a tree that still contains -- or still references --
# a branch-only working document (root-level `v*-polish.md`, e.g.
# v0.9.9-polish.md). Such a document exists ONLY on a polish branch and must be
# deleted, and de-referenced, in the final pre-merge commit; a production
# release is cut from main, so none may remain.
#
# Deliberately SEPARATE from release_validate_current_documentation: that
# validator runs in `--preflight`, which exercises the live checked-in tree
# (where the polish document legitimately still exists during branch work). This
# gate is invoked only on the actual release-staging path, after preflight has
# exited, so it fails a real release closed without breaking the preflight
# capability probe. The retained docs/v0.9.6_post_release_polish.md is under
# docs/ and does not match the root pattern, so it is unaffected.
release_reject_branch_only_documents() {
	[ "$#" -eq 1 ] || return 2
	local repo_root=$1 branch_doc reference_file find_pid grep_output grep_status
	local -a present_polish_docs=() polish_doc_references=()

	while IFS= read -r -d '' branch_doc; do
		[ -n "$branch_doc" ] && present_polish_docs+=("${branch_doc#$repo_root/}")
	done < <(find "$repo_root" -maxdepth 1 -type f -name 'v*-polish.md' -print0)
	find_pid=$!
	wait "$find_pid" \
		|| _release_documentation_error "could not scan for branch-only polish documents" || return
	[ "${#present_polish_docs[@]}" -eq 0 ] \
		|| _release_documentation_error "branch-only polish document(s) must be deleted before release: ${present_polish_docs[*]}" || return

	# A durable file that still NAMES such a document (v<ver>-polish.md) dangles
	# once it is deleted. Exclude this checker and its regression, which
	# necessarily carry the pattern as tooling -- the same self-reference the
	# Makefile name contract allowlists.
	if grep_output=$(grep -rlIE 'v[0-9][0-9.]*-polish\.md' "$repo_root" \
		--exclude-dir=.git \
		--exclude='release-documentation.sh' \
		--exclude='test_release_preflight.sh'); then
		while IFS= read -r reference_file; do
			[ -n "$reference_file" ] && polish_doc_references+=("${reference_file#$repo_root/}")
		done <<<"$grep_output"
	else
		grep_status=$?
		[ "$grep_status" -eq 1 ] \
			|| _release_documentation_error "could not scan for branch-only polish-document references" || return
	fi
	[ "${#polish_doc_references[@]}" -eq 0 ] \
		|| _release_documentation_error "durable file(s) still reference a branch-only polish document (repoint to CHANGELOG.md / Git history): ${polish_doc_references[*]}" || return
}

release_render_scope() {
	[ "$#" -eq 0 ] || return 2
	printf 'Release scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT),\n'
	printf 'PIC10F322, PIC10F320, and PIC12F675.\n\n'
}

release_render_validation() {
	[ "$#" -eq 1 ] || return 2
	local hours=$1
	printf -- '- **Validation:** `make test-long` + `make attiny202-test` + `make attiny202-test-target`'
	printf ' + `make pic10f322-test` + `make pic10f322-test-target-variants`'
	printf ' + `make pic10f320-test` + `make pic10f320-test-target-variants`'
	printf ' + `make pic12f675-test pic12f675-test-target-variants` (one retained matrix)'
	printf ' (real-image fault handling, firmware/model ctx_ lock-step, and physical-output checks across AVR-XT and all three PIC parts)'
	printf ' + %s-h parallel soak of every release soak combination (see evidence/).\n' "$hours"
}

release_render_pic_toolchain_rows() {
	[ "$#" -eq 6 ] || return 2
	local pic_cc=$1 shared_xc8_version=$2
	local pic10f320_cc=$3 pic10f320_xc8_version=$4
	local pic_dfp=$5 pic10f320_dfp=$6
	printf -- '| PIC10F322/PIC12F675 XC8 (`PIC_CC=%s`) | %s |\n' \
		"$pic_cc" "$shared_xc8_version"
	printf -- '| PIC10F320 XC8 (`PIC10F320_CC=%s`) | %s |\n' \
		"$pic10f320_cc" "$pic10f320_xc8_version"
	printf -- '| PIC10F322/PIC12F675 DFP (`PIC_DFP`) | %s |\n' "$pic_dfp"
	printf -- '| PIC10F320 DFP (`PIC10F320_DFP`) | %s |\n' "$pic10f320_dfp"
}

release_render_pic12f675_flashing() {
	[ "$#" -eq 1 ] || return 2
	local release_tag=$1
	printf '%s\n' \
		'### PIC12F675 guarded programming' \
		'' \
		'Externally power the board; this workflow does not request programmer-supplied Vdd.' \
		'Do not invoke a raw programmer write for this part. For each device, choose' \
		'new baseline and result paths whose parent directory already exists, then run' \
		'the read-only preflight and program steps as one fail-stop transaction. Replace' \
		'`cd4053_simple` with one supported output stage when needed:' \
		'`cd4053_simple`, `cd4053_with_mute`, or `tq2_l2_5v_relay`.' \
		'' \
		'```sh' \
		"release_tag=$(printf '%q' "$release_tag") &&" \
		'repo=$(git rev-parse --show-toplevel) &&' \
		'head_commit=$(git -C "$repo" rev-parse --verify "HEAD^{commit}") &&' \
		'tag_commit=$(git -C "$repo" rev-parse --verify "refs/tags/$release_tag^{commit}") &&' \
		'worktree_status=$(git -C "$repo" status --porcelain=v1 --untracked-files=normal) &&' \
		'test "$head_commit" = "$tag_commit" && test -z "$worktree_status" &&' \
		'evidence_root=$(dirname "$repo") &&' \
		'baseline="$evidence_root/pic12f675-factory-baseline.json" &&' \
		'result="$evidence_root/pic12f675-program-result" &&' \
		'test ! -e "$baseline" && test ! -e "$result" &&' \
		'make -C "$repo" pic12f675-preflight \' \
		'  PIC12F675_READ_PROG=pk2cmd \' \
		'  PIC12F675_TRIM_EVIDENCE="$baseline" &&' \
		'make -C "$repo" pic12f675-release-program \' \
		'  VARIANT=cd4053_simple \' \
		'  PIC12F675_RELEASE_TAG="$release_tag" \' \
		'  PIC12F675_PROG=pk2cmd \' \
		'  PIC12F675_PROG_KIND=pk2cmd \' \
		'  PIC12F675_READ_PROG=pk2cmd \' \
		'  PIC12F675_TRIM_EVIDENCE="$baseline" \' \
		'  PIC12F675_BENCH_RESULT="$result"' \
		'```' \
		'' \
		'If an interruption leaves `reservation.json` but no `result.json`, the' \
		'transaction is **PENDING**. Keep physical custody of the same attached device.' \
		'Do not write, reflash, capture a new baseline, or reuse the result path. From' \
		'this same release checkout, resolve it with the same variant and tool identities:' \
		'' \
		'```sh' \
		'make -C "$repo" pic12f675-finalize \' \
		'  VARIANT=cd4053_simple \' \
		"  PIC12F675_RELEASE_TAG=$(printf '%q' "$release_tag") \\" \
		'  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \' \
		'  PIC12F675_READ_PROG=pk2cmd \' \
		'  PIC12F675_TRIM_EVIDENCE="$baseline" \' \
		'  PIC12F675_BENCH_RESULT="$result"' \
		'```' \
		'' \
		'Finalization revalidates the same signed release tag and image, every reserved' \
		'identity, and the separately retained image' \
		'before hardware access and never invokes writer arguments. It verifies the reader' \
		'version before a full-device read, uses retry-safe private attempts, and exclusively' \
		'publishes the recovered PASS/FAIL `result.json`; FAIL is a' \
		'resolved forensic record, not permission to retry the write, and an existing result' \
		'is immutable.' \
		'' \
		'The guarded workflow rejects an image that explicitly programs OSCCAL word' \
		'`0x3FF`, requires the image BG field to remain erased, compares the live device' \
		'with the baseline immediately before writing.' \
		'Post-write identity, OSCCAL, BG, CONFIG, and programmed bytes are checked and recorded' \
		'as mandatory evidence.' \
		'This does not prove that a real pk2cmd or ipecmd erase/program operation preserves' \
		'factory trim: preservation remains hardware-unvalidated until the `1.x.y` bench' \
		'pass. A failure is detected only after the write and may already have damaged the device.' \
		'The device may still appear to work with wrong timing or BOR/POR thresholds.' \
		'The release target rechecks a clean checkout of this exact annotated release tag,' \
		'verifies the pinned tag and checksum signatures, and requires the private fresh' \
		'build to match the selected digest in the complete signed release image set.' \
		'It does not consume a downloaded release HEX. Baseline and result evidence stay' \
		'outside the worktree so those checks remain exact. Transient reads and the private build use `TMPDIR` when set,' \
		'otherwise `XDG_RUNTIME_DIR`, otherwise `HOME`. The selected root must exist, be' \
		'current-user-private, and have only root/current-user-owned non-writable ancestors.' \
		'Shared `/tmp` and `/var/tmp` roots are rejected; the path is limited to letters,' \
		'digits, spaces, `/`, `.`, `_`, and `-`.' \
		'Handled exits remove the transient directories. No ipecmd hardware' \
		'procedure is qualified: its software-tested write route would also require a' \
		'pk2cmd reader before and after the write, and no safe attachment/handoff has been' \
		'validated.' \
		''
}

release_render_flashing() {
	[ "$#" -eq 2 ] || return 2
	local flash_commands=$1 release_tag=$2 image command
	[ -s "$flash_commands" ] && [ -f "$flash_commands" ] \
		&& [ ! -L "$flash_commands" ] || return 2
	while IFS=$'\t' read -r image command; do
		[ -n "$image" ] && [ -n "$command" ] || return 2
		case "$image" in
			*-pic12f675-*.hex) return 2 ;;
		esac
	done < "$flash_commands"

	printf '%s\n' \
		'## Flashing' \
		'' \
		'AVR images require the design fuse bytes in addition to the flash write' \
		'(the table above lists them per image). PIC images embed their CONFIG word.' \
		'PIC12F675 has no per-image shortcut because every write requires the guarded' \
		'device-specific transaction below.' \
		'' \
		'```'
	sort "$flash_commands" | while IFS=$'\t' read -r image command; do
		printf '# %s\n%s\n\n' "$image" "$command"
	done
	printf '```\n\n'
	release_render_pic12f675_flashing "$release_tag"
}

release_render_reproduction_commands() {
	[ "$#" -eq 11 ] || return 2
	local version=$1 release_image_dirs=$2
	local avr_build_dir=$3 xt_build_dir=$4 pic10f322_build_dir=$5
	local pic10f320_build_dir=$6 pic12f675_build_dir=$7
	local pic_cc=$8 pic_dfp=$9 pic10f320_cc=${10} pic10f320_dfp=${11} dir i
	local -a dirs expected_dirs
	read -r -a dirs <<<"$release_image_dirs"
	expected_dirs=("$avr_build_dir" "$xt_build_dir" "$pic10f322_build_dir" \
		"$pic10f320_build_dir" "$pic12f675_build_dir")
	[ "${#dirs[@]}" -eq "${#expected_dirs[@]}" ] || return 2
	for i in "${!dirs[@]}"; do
		[ "${dirs[$i]}" = "${expected_dirs[$i]}" ] || return 2
	done

	printf 'git checkout %q\n' "$version"
	printf '# install the pinned toolchain (see TOOLCHAIN.adoc), then:\n'
	printf 'make clean AVR_BUILD_DIR=%q XT_BUILD_DIR=%q' \
		"$avr_build_dir" "$xt_build_dir"
	printf ' PIC10F322_BUILD_DIR=%q PIC10F320_BUILD_DIR=%q PIC12F675_BUILD_DIR=%q\n' \
		"$pic10f322_build_dir" "$pic10f320_build_dir" "$pic12f675_build_dir"
	printf 'make attiny13a attiny85 attiny45 AVR_BUILD_DIR=%q\n' "$avr_build_dir"
	printf 'make attiny202 XT_BUILD_DIR=%q STRICT_TOOLS=1\n' "$xt_build_dir"
	printf 'make pic10f322 PIC10F322_BUILD_DIR=%q PIC_CC=%q PIC_DFP=%q\n' \
		"$pic10f322_build_dir" "$pic_cc" "$pic_dfp"
	printf 'make pic10f320-variants PIC10F320_BUILD_DIR=%q' "$pic10f320_build_dir"
	printf ' PIC10F320_CC=%q PIC10F320_DFP=%q\n' "$pic10f320_cc" "$pic10f320_dfp"
	printf 'make pic12f675 PIC12F675_BUILD_DIR=%q PIC_CC=%q PIC_DFP=%q\n' \
		"$pic12f675_build_dir" "$pic_cc" "$pic_dfp"
	printf 'scripts/verify-release-images.sh %q' "release/$version"
	for dir in "${dirs[@]}"; do printf ' %q' "$dir"; done
	printf '\n'
}

release_render_commit_message() {
	[ "$#" -eq 5 ] || return 2
	local version=$1 release_mode=$2 git_short=$3 image_count=$4 hours=$5
	local release_description

	case "$release_mode" in
		dry-run)
			release_description='Non-publishable dry-run rehearsal images'
			;;
		production)
			release_description='Prebuilt, fully-validated firmware images'
			;;
		*)
			return 2
			;;
	esac
	printf 'release: firmware %s\n\n' "$version"
	printf '%s for %s.\n\n' "$release_description" "$version"
	printf 'Built from %s with the toolchain pinned in TOOLCHAIN.adoc.\n' "$git_short"
	printf 'Scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT), PIC10F322,\n'
	printf 'PIC10F320, and PIC12F675 -- %d images, checked against the canonical RELEASE_IMAGES set the\n' \
		"$image_count"
	printf 'Makefile declares rather than against whatever the build produced.\n\n'
	printf 'Validation: make test-long + make attiny202-test + make attiny202-test-target\n'
	printf '+ make pic10f322-test + make pic10f322-test-target-variants\n'
	printf '+ make pic10f320-test + make pic10f320-test-target-variants\n'
	printf '+ make pic12f675-test pic12f675-test-target-variants (one retained matrix)\n'
	printf '+ %s-h parallel soak of every release soak combination (evidence under\n' "$hours"
	printf 'release/%s/evidence/).\n\n' "$version"
	printf 'Reproducibility is pinned by release/%s/SHA256SUMS and verified on a\n' "$version"
	printf 'clean runner by .github/workflows/release.yml when the tag is pushed.\n'
}
