#!/usr/bin/env bash
#
# make-release.sh -- build, exhaustively validate, and STAGE a prebuilt
# firmware release for this project.
#
# WHY THIS EXISTS
#   The firmware's whole value proposition is trust: an extensive test and
#   validation suite backs the SOURCE. This script extends that same confidence
#   to PREBUILT BINARIES so that someone who just wants to flash a chip does not
#   have to install a cross-toolchain or compile anything -- yet can still verify
#   the image is exactly what the (tested) source produces.
#
#   The trust model rests on two legs:
#     1. PROVENANCE -- every released image carries a MANIFEST recording the git
#        commit, the exact toolchain versions, the per-image fuse bytes / CONFIG
#        word, and the validation evidence (test-long + both ATtiny202 gates +
#        both pre-hardware and real-target aggregates for all three PIC parts +
#        18-combination 24-h soak, or the 1-h soak an --express release records
#        as such in both QUALIFICATION and MANIFEST.md).
#     2. REPRODUCIBILITY -- the Intel-HEX images are byte-deterministic for a
#        fixed toolchain (objcopy ihex carries only code/data bytes, no
#        timestamps/paths). SHA256SUMS pins those bytes; the tag-triggered CI
#        (.github/workflows/release.yml) rebuilds from the tag on a clean runner
#        and FAILS the release unless its fresh images reproduce these hashes.
#        That green check -- not this script -- is the public attestation that
#        "this binary IS the tagged source."
#
# WHAT IT DOES (in order)
#   0. Preconditions: clean tree, valid version, tag not already present, and
#      EVERY required tool present. Unlike the dev-time targets (which skip
#      cleanly when a tool is missing), a release FAILS LOUD on any absence -- a
#      gate must never go green on a check that silently did nothing.
#   1. Clean-build every release-supported image: AVR Classic, ATtiny202,
#      PIC10F322, PIC10F320, and PIC12F675. The built set is then cross-checked
#      against the CANONICAL set the Makefile declares (RELEASE_IMAGES). This independent
#      check catches a forgotten build step -- an enumeration derived from the same
#      variant matrices as the build commands shrinks in lock-step with an
#      omission and agrees with itself (merge plan §10, §14.8).
#   2. Run `make test-long`, `make attiny202-test`,
#      `make attiny202-test-target`, `make pic10f322-test`,
#      `make pic10f322-test-target-variants`, `make pic10f320-test`,
#      `make pic10f320-test-target-variants`, and one two-goal Make graph for
#      `pic12f675-test pic12f675-test-target-variants` (the full qualification
#      gates for every release-supported target), then measure the strict
#      final-candidate resource evidence those gates just produced. That last
#      check consumes only this step's logs and the built images -- nothing the
#      soak produces -- so it runs HERE, where a stale documented figure costs
#      seconds instead of a 24-hour soak. It is measured again after the soak,
#      and only that second record is retained as release evidence.
#   3. Run ALL release soak combinations IN PARALLEL for the full
#      duration, collecting a pass/fail verdict and evidence from each. That is
#      6 AVR Classic + 3 AVR-XT + 3 PIC10F322 + 3 PIC10F320 + 3 PIC12F675 = 18
#      combos.
#   4. Recheck source HEAD + cleanliness, then stage release/<VERSION>/ : the
#      .hex images, SHA256SUMS, a provenance MANIFEST, a README, the
#      soak/validation evidence, and a commit message. Re-validate the bounded
#      current-release declarations against the inventory actually staged.
#   5. STOP. Print the exact git + signing commands for the human to run. This
#      script NEVER commits, tags, signs, or pushes -- per project policy all
#      modifying git operations are done by hand.
#
# WHERE THIS SITS IN THE RELEASE SEQUENCE
#   A release is a four-step sequence spanning two commits and a signed tag.
#   This script owns exactly one of those steps:
#     1. SOURCE FINALIZATION -- an ordinary commit on main that finalizes
#        CHANGELOG.md and the bounded current-release declarations for vX.Y.Z
#        (release-documentation.sh's current_documents). This commit is the
#        source contract and is what gets qualified.
#     2. PRODUCTION STAGING -- this script. It refuses to start unless step 1 is
#        already committed (step 0 validates the declarations), and it stages
#        release/<VERSION>/ without committing anything.
#     3. ARTIFACT COMMIT -- one commit whose sole parent is the qualified source
#        commit and which changes only release/<VERSION>/.
#     4. SIGNED TAG + PUSH -- the tag names the artifact commit; tag CI rebuilds
#        and republishes from it.
#   Steps 1 and 3 are necessarily separate commits: verify-release-history.sh
#   rejects a release whose qualified source commit ALREADY contains
#   release/<VERSION>/QUALIFICATION. So between step 1 and step 3 main carries
#   the vX.Y.Z contract while release/vX.Y.Z/ does not yet exist. That window is
#   intended and is bounded by the qualification run; if the release is
#   abandoned or postponed, step 1 must be reverted or corrected on main rather
#   than left standing. See release/README.md, "How a release is sequenced".
#
# USAGE
#   scripts/make-release.sh [options] <version>
#     <version>                vX.Y.Z (semantic version, leading 'v'); required
#                              except in --preflight mode
#   options:
#     --preflight              run every release capability/precondition check,
#                              then exit before cleaning, building, or staging
#     --dry-run                rehearse the whole pipeline with a SHORT soak
#                              (does not produce a real release; output is
#                              clearly marked and no git commands are emitted)
#     --express                stage a REAL, publishable release whose soak runs
#                              1 h per combination instead of 24 h. Every other
#                              gate runs exactly as it does for a production
#                              release, and the shortened soak is recorded --
#                              release_mode=express in QUALIFICATION, a banner
#                              in MANIFEST.md, and the true duration in both.
#     --soak-duration-ms N     per-combo soak duration (default/minimum for a
#                              production release: 24 h; --express lowers that
#                              floor to 1 h; dry runs may use less)
#     --jobs N                 max concurrent soak combos (default: all of them)
#     --output-dir DIR         where to stage (default release/<version>)
#     -h | --help              this help
#
# This script is intentionally long-running (~24 h, dominated by the parallel
# soaks; ~1 h under --express). Run it on a machine that can stay up, with all
# toolchains installed (AVR + XC8/DFP + simavr + gpsim/gpsim-dev + analyzers).
# See TOOLCHAIN.adoc.

set -euo pipefail

# `make release` already owns the worktree lock. Direct execution acquires the
# same lock for the complete build/validation/staging pipeline so nested Make
# calls cannot interleave with another invocation's artifacts.
REPO_HINT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO_LOCK_ID=$(stat -Lc '%d:%i' "$REPO_HINT" 2>/dev/null) \
	|| { printf 'FATAL: stat is required to identify the worktree lock\n' >&2; exit 1; }
if [ "${_MAKE_SERIAL_LOCK_HELD:-}" != "$REPO_LOCK_ID" ]; then
	command -v flock >/dev/null 2>&1 \
		|| { printf 'FATAL: flock is required to serialize release artifacts\n' >&2; exit 1; }
	# --no-fork keeps this process as the release orchestrator, so HUP/INT/TERM
	# reach its worker-cleanup traps instead of stopping a parent flock process.
	exec flock --no-fork "$REPO_HINT/.make.lock" env _MAKE_SERIAL_LOCK_HELD="$REPO_LOCK_ID" \
		"$REPO_HINT/scripts/make-release.sh" "$@"
fi

# ----------------------------------------------------------------------------
# Small output helpers (stderr for status; stdout reserved for the final recipe)
# ----------------------------------------------------------------------------
_c()  { tput "$@" 2>/dev/null || true; }
BOLD=$(_c bold); RED=$(_c setaf 1); GRN=$(_c setaf 2); YEL=$(_c setaf 3); RST=$(_c sgr0)

section() { printf '\n%s========== %s ==========%s\n' "$BOLD" "$*" "$RST" >&2; }
log()     { printf '%s\n' "$*" >&2; }
ok()      { printf '%sOK%s   %s\n' "$GRN" "$RST" "$*" >&2; }
warn()    { printf '%sWARN%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()     { printf '%sFATAL%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
MAKE_VERSION=${VERSION-}
MAKE_RELEASE_ARGS=${RELEASE_ARGS-}
VERSION=""
VERSION_WAS_SUPPLIED=0
PREFLIGHT=0
DRY_RUN=0
EXPRESS=0
RELEASE_MODE=production
# Independent local-release policy pins. These intentionally do not come from
# Make, so an unintended production-policy mismatch fails qualification.
readonly RELEASE_XT_STATIC_RAM_LIMIT=16
readonly RELEASE_XT_STACK_MAX_FRAME=32
readonly RELEASE_PIC12F675_DATA_LIMIT=48
# Canonical project URL. MANIFEST.md is used verbatim as the GitHub Release
# body, where repo-relative links do not resolve, so any link it carries must
# be absolute. Not derived from `git remote` on purpose: that would vary with
# the operator's SSH-vs-HTTPS remote and silently change published notes.
REPO_URL=https://github.com/matt-garman/mcu-bypass-firmware
MIN_RELEASE_SOAK_MS=86400000
# An express release is a real, publishable release that trades soak hours for
# turnaround. It moves the floor rather than removing it: every other gate still
# runs in full, and one hour is still 60 liveness round-trips per combination at
# the 60 s interval below. scripts/verify-release-qualification.sh enforces this
# same floor for release_mode=express, so a shorter express run is not
# publishable either.
MIN_EXPRESS_SOAK_MS=3600000
MAX_SOAK_DURATION_MS=4294967294    # uint32_t loop bound; preserve t + 1
SOAK_DURATION_MS=$MIN_RELEASE_SOAK_MS
SOAK_DURATION_WAS_SUPPLIED=0
SOAK_LIVENESS_INTERVAL_MS=60000
JOBS=""                            # empty => all combinations
OUTPUT_DIR=""
MAKE_RELEASE_ARGS_ACTIVE=0

usage() { sed -n '2,200p' "$0" | sed -n '/^# USAGE/,/^$/p' | sed 's/^# \{0,1\}//'; }

# The Make target exports RELEASE_ARGS rather than interpolating it into shell
# syntax. Split its documented whitespace-delimited option list without eval;
# direct script invocations already provide exact argv and ignore this channel.
if [ "$#" -eq 0 ] && [ -n "$MAKE_RELEASE_ARGS" ]; then
	IFS=$' \t\n' read -r -d '' -a make_release_argv \
		< <(printf '%s\0' "$MAKE_RELEASE_ARGS")
	set -- "${make_release_argv[@]}"
	MAKE_RELEASE_ARGS_ACTIVE=1
fi

while [ $# -gt 0 ]; do
	case "$1" in
		--preflight)          PREFLIGHT=1; shift ;;
		--dry-run)            DRY_RUN=1; shift ;;
		--express)            EXPRESS=1; shift ;;
		--soak-duration-ms)   SOAK_DURATION_MS="${2:?--soak-duration-ms needs a value}"
			SOAK_DURATION_WAS_SUPPLIED=1; shift 2 ;;
		--jobs)               JOBS="${2:?--jobs needs a value}"; shift 2 ;;
		--output-dir)         OUTPUT_DIR="${2:?--output-dir needs a value}"; shift 2 ;;
		-h|--help)            usage; exit 0 ;;
		-*)                   die "unknown option: $1 (try --help)" ;;
		*)                    [ "$MAKE_RELEASE_ARGS_ACTIVE" -eq 0 ] \
				|| die "RELEASE_ARGS may contain options only, not positional value: $1"
			[ -z "$VERSION" ] || die "unexpected extra argument: $1"; VERSION="$1"; VERSION_WAS_SUPPLIED=1; shift ;;
	esac
done

# Each option below names what the run IS: --express a publishable release with
# a shortened soak, --dry-run a rehearsal that is not a release, --preflight a
# capability probe that builds nothing. Any pair leaves the recorded mode
# ambiguous, so all three pairs are refused here, before anything is read or
# built. The mode-defining pair is checked first so the diagnostic names the
# contradiction the operator actually wrote.
[ "$EXPRESS" -eq 0 ] || [ "$DRY_RUN" -eq 0 ] \
	|| die "--express and --dry-run are mutually exclusive"
[ "$PREFLIGHT" -eq 0 ] || [ "$DRY_RUN" -eq 0 ] \
	|| die "--preflight and --dry-run are mutually exclusive"
[ "$EXPRESS" -eq 0 ] || [ "$PREFLIGHT" -eq 0 ] \
	|| die "--preflight and --express are mutually exclusive"
if [ "$VERSION_WAS_SUPPLIED" -eq 0 ] && [ -n "$MAKE_VERSION" ]; then
	# GNU Make exports command-line variables to recipes. Reading VERSION from
	# that environment keeps arbitrary bytes out of the recipe's shell syntax;
	# semantic/ref validation below still treats it exactly like a positional arg.
	VERSION=$MAKE_VERSION
	VERSION_WAS_SUPPLIED=1
fi
if [ -z "$VERSION" ]; then
	[ "$PREFLIGHT" -eq 1 ] \
		|| die "no <version> given (e.g. v1.0.0). Try --help."
	# Capability checks need a safe prospective staging path, but not a release
	# number. A caller that wants tag/output-state warnings can still supply one.
	VERSION=v0.0.0-preflight
fi
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "version '$VERSION' is not vX.Y.Z (optionally -suffix)"

# GNU Make consumes these channels before the Makefile can defend itself. Check
# the script's original environment before the first query so direct execution
# cannot redirect configuration, install `--eval` text, or make a failed nested
# recipe look successful. Long options can arrive here already normalized into
# the compact first word of MAKEFLAGS/MFLAGS, so inspect both forms.
[ -z "${MAKEFILES-}" ] \
	|| die "MAKEFILES injection is not supported by production release configuration"
release_make_option_text=" ${MAKEFLAGS-} ${MFLAGS-} ${GNUMAKEFLAGS-} "
case "$release_make_option_text" in
	*" --eval"*|*" --file"*|*" --makefile"*|*" -f"*)
		die "GNU Make --eval/-f/--file/--makefile options are not supported by production release configuration"
		;;
esac
release_make_semantic_mode=
release_make_semantic_channel=
for release_make_channel in MAKEFLAGS MFLAGS GNUMAKEFLAGS; do
	release_make_value=${!release_make_channel-}
	read -r -a release_make_words <<<"$release_make_value"
	release_make_word_index=0
	for release_make_word in "${release_make_words[@]}"; do
		release_make_word_index=$((release_make_word_index + 1))
		release_make_compact=
		case "$release_make_word" in
			--) break ;;
			--ignore-errors) release_make_semantic_mode='-i/--ignore-errors' ;;
			--dry-run|--just-print|--recon) release_make_semantic_mode='-n/--dry-run' ;;
			--question) release_make_semantic_mode='-q/--question' ;;
			--touch) release_make_semantic_mode='-t/--touch' ;;
			--*|*=*) continue ;;
			-*) release_make_compact=${release_make_word#-} ;;
			*)
				[ "$release_make_word_index" -eq 1 ] || continue
				[[ "$release_make_word" =~ ^[A-Za-z]+$ ]] || continue
				release_make_compact=$release_make_word
				;;
		esac
		if [ -z "$release_make_semantic_mode" ]; then
			case "$release_make_compact" in
				*i*) release_make_semantic_mode='-i/--ignore-errors' ;;
				*n*) release_make_semantic_mode='-n/--dry-run' ;;
				*q*) release_make_semantic_mode='-q/--question' ;;
				*t*) release_make_semantic_mode='-t/--touch' ;;
			esac
		fi
		if [ -n "$release_make_semantic_mode" ]; then
			release_make_semantic_channel=$release_make_channel
			break 2
		fi
	done
done
[ -z "$release_make_semantic_mode" ] \
	|| die "GNU Make recipe-semantic option $release_make_semantic_mode from $release_make_semantic_channel is not supported by production release configuration; rerun without ignore-errors, dry-run, question, or touch flags"

# Bootstrap prerequisites: both are consumed before section 0 can build its
# complete selected-tool inventory. Keep the explicit inventory entries there
# too, but diagnose an absent command before its first use here.
command -v git >/dev/null 2>&1 \
	|| die "Git is required to validate release tags and repository provenance"
command -v make >/dev/null 2>&1 \
	|| die "GNU Make is required to read release configuration (print-<VAR>)"

# A marker is not proof of ownership. The serialization wrapper leaves its
# locked file descriptor inherited by this process; find that exact inode and
# reassert the nonblocking lock on the inherited open-file description. A caller
# that merely exports the marker has no descriptor and is refused. If it passes
# an unlocked descriptor for the right file, this call acquires and retains the
# lock on that descriptor, so concurrency is still excluded.
command -v flock >/dev/null 2>&1 \
	|| die "flock is required to verify the inherited release lock"
REPO_LOCK_FILE_ID=$(stat -Lc '%d:%i' "$REPO_HINT/.make.lock" 2>/dev/null) \
	|| die "could not identify the inherited worktree lock"
REPO_LOCK_FD=
REPO_LOCK_FD_MATCHED=0
for candidate_fd in /proc/$$/fd/[0-9]*; do
	candidate_lock_id=$(stat -Lc '%d:%i' "$candidate_fd" 2>/dev/null) || continue
	if [ "$candidate_lock_id" = "$REPO_LOCK_FILE_ID" ]; then
		REPO_LOCK_FD_MATCHED=1
		candidate_fd_number=${candidate_fd##*/}
		if flock -n "$candidate_fd_number"; then
			REPO_LOCK_FD=$candidate_fd_number
			break
		fi
	fi
done
if [ -z "$REPO_LOCK_FD" ]; then
	[ "$REPO_LOCK_FD_MATCHED" -eq 1 ] \
		&& die "no inherited worktree lock descriptor is exclusively held"
	die "_MAKE_SERIAL_LOCK_HELD has no inherited lock descriptor"
fi

git check-ref-format "refs/tags/$VERSION" >/dev/null 2>&1 \
	|| die "version '$VERSION' is not a valid Git tag name"

# The C/C++ soak loops use uint32_t millisecond counters. Validate before any
# preconditions or builds so a bad value cannot wrap to a short/empty passing
# run. Canonical decimal syntax also keeps later shell arithmetic unambiguous.
[[ "$SOAK_DURATION_MS" =~ ^[1-9][0-9]*$ ]] \
	|| die "--soak-duration-ms must be a positive base-10 integer"
if [ "${#SOAK_DURATION_MS}" -gt "${#MAX_SOAK_DURATION_MS}" ] \
		|| { [ "${#SOAK_DURATION_MS}" -eq "${#MAX_SOAK_DURATION_MS}" ] \
			&& [[ "$SOAK_DURATION_MS" > "$MAX_SOAK_DURATION_MS" ]]; }; then
	die "--soak-duration-ms must not exceed $MAX_SOAK_DURATION_MS"
fi
if [ -n "$JOBS" ] && ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
	die "--jobs must be a positive base-10 integer"
fi
if [ "$EXPRESS" -eq 1 ]; then
	RELEASE_MODE=express
	# An operator who names a duration gets exactly that duration, checked
	# against the express floor below. Only the untouched 24-h default is
	# shortened, so `--express --soak-duration-ms <24 h>` cannot be silently
	# downgraded into the very short run the flag exists to allow.
	[ "$SOAK_DURATION_WAS_SUPPLIED" -eq 1 ] || SOAK_DURATION_MS=$MIN_EXPRESS_SOAK_MS
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$EXPRESS" -eq 0 ] \
		&& [ "$SOAK_DURATION_MS" -lt "$MIN_RELEASE_SOAK_MS" ]; then
	die "production releases require --soak-duration-ms >= $MIN_RELEASE_SOAK_MS (24 h); use --express for a 1-h publishable release, or --dry-run for a short rehearsal"
fi
if [ "$EXPRESS" -eq 1 ] && [ "$SOAK_DURATION_MS" -lt "$MIN_EXPRESS_SOAK_MS" ]; then
	die "express releases require --soak-duration-ms >= $MIN_EXPRESS_SOAK_MS (1 h); use --dry-run for a short rehearsal"
fi

if [ "$DRY_RUN" -eq 1 ]; then
	RELEASE_MODE=dry-run
	# A dry run is an explicit rehearsal: shorten the soak so the whole pipeline
	# finishes quickly, and tolerate an uncommitted tree (you typically rehearse
	# BEFORE committing the release scaffolding itself).
	[ "$SOAK_DURATION_MS" = "$MIN_RELEASE_SOAK_MS" ] && SOAK_DURATION_MS=60000
fi
# A short rehearsal must still execute at least one responsiveness round-trip.
[ "$SOAK_DURATION_MS" -lt "$SOAK_LIVENESS_INTERVAL_MS" ] \
	&& SOAK_LIVENESS_INTERVAL_MS=$SOAK_DURATION_MS
[ "$DRY_RUN" -eq 1 ] \
	&& warn "DRY RUN: short ${SOAK_DURATION_MS}ms soak (liveness interval ${SOAK_LIVENESS_INTERVAL_MS}ms); output is NOT a real release."
[ "$EXPRESS" -eq 1 ] \
	&& warn "EXPRESS: publishable release with a ${SOAK_DURATION_MS}ms soak per combination instead of ${MIN_RELEASE_SOAK_MS}ms; every other gate runs in full and the shortened soak is recorded in QUALIFICATION and MANIFEST.md."

# ----------------------------------------------------------------------------
# Locate the repo and read the Makefile's single source of truth
# ----------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$REPO_ROOT"
# Load this once at startup so an edit during the long run cannot replace the
# final provenance-check implementation used by this process.
# shellcheck source=release-provenance.sh
source "$REPO_ROOT/scripts/release-provenance.sh"
declare -F release_source_is_unchanged >/dev/null \
	|| die "release provenance checker did not define its required function"
declare -F release_tool_version_line >/dev/null \
	|| die "release provenance checker did not define its tool-version function"
declare -F release_pinned_version_matches >/dev/null \
	|| die "release provenance checker did not define its version-pin function"
declare -F release_require_main_branch >/dev/null \
	|| die "release provenance checker did not define its main-branch function"
declare -F release_output_path_is_safe >/dev/null \
	|| die "release provenance checker did not define its output-path function"
declare -F release_terminate_workers >/dev/null \
	|| die "release provenance checker did not define its worker-cleanup function"
declare -F release_jobs_cap >/dev/null \
	|| die "release provenance checker did not define its jobs-cap function"
declare -F release_hash_classic_avr_images >/dev/null \
	|| die "release provenance checker did not define its classic-AVR image hash function"
declare -F release_stage_classic_avr_images >/dev/null \
	|| die "release provenance checker did not define its classic-AVR staging function"
# Keep generated release prose in pure stdout renderers so focused regressions
# can execute the same document bytes without running the release pipeline.
# shellcheck source=release-documentation.sh
source "$REPO_ROOT/scripts/release-documentation.sh" \
	|| die "release documentation helper could not be loaded"
for renderer in release_validate_current_documentation \
		release_validate_staged_documentation \
		release_reject_branch_only_documents \
		release_validate_hardware_claims \
		release_validate_pic12f675_finalization \
		release_validate_pic12f675_finalization_document \
		release_validate_pic12f675_flashing_helper \
		release_validate_flashing_simplicity_status \
		release_render_scope release_render_validation \
		release_render_pic_toolchain_rows release_render_pic12f675_flashing \
		release_render_flashing \
		release_render_reproduction_commands \
		release_render_commit_message; do
	declare -F "$renderer" >/dev/null \
		|| die "release documentation helper did not define $renderer"
done
# shellcheck source=release-signing-policy.sh
source "$REPO_ROOT/scripts/release-signing-policy.sh" \
	|| die "release signing policy could not be loaded"

# GNU Make expands a few parse-time shell expressions through the platform awk
# before AWK itself can be read from Makefile truth. Diagnose that bootstrap
# prerequisite explicitly instead of failing inside an opaque print-<VAR> query.
command -v awk >/dev/null 2>&1 \
	|| die "awk is required to read release configuration from the Makefile"

# Echo one Makefile variable. --no-print-directory is load-bearing and -s does
# NOT imply it: Make enables -w in a sub-make and propagates a literal w through
# MAKEFLAGS, where it OVERRIDES -s and wraps every reply in "Entering/Leaving
# directory" lines. `make release` reaches this script with MAKEFLAGS clear, so
# today only the flag's absence is theoretical -- but a release invoked one
# level deeper (`make -C . release`, or from another Make) would feed a banner
# into every value below, and from there into the staged MANIFEST. Ask silently,
# always, rather than depend on the caller's nesting depth.
mkv() { make -s --no-print-directory print-"$1"; }
path_from_repo() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*)  printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
	esac
}
tool_from_repo() {
	case "$1" in
		*/*) path_from_repo "$1" ;;
		*)   printf '%s\n' "$1" ;;
	esac
}

# The parent Makefile globally exports hardware-programming selectors and the
# gpsim timeout for their standalone targets. They are not release inputs, but
# without clearing them a nested configuration query sees the parent's canonical
# defaults as caller environment. Command-line forms remain in MAKEFLAGS and are
# rejected by the Make guard. For direct script use, only the canonical timeout
# may be inherited; programming selectors are irrelevant and removed.
inherited_gpsim_timeout=${GPSIM_TIMEOUT_SECONDS-}
case "$inherited_gpsim_timeout" in
	''|60) ;;
	*) die "GPSIM_TIMEOUT_SECONDS is not a supported production release override" ;;
esac
unset MAKE GPSIM_TIMEOUT_SECONDS PIC12F675_PART PIC12F675_PROG \
	PIC12F675_PROG_KIND PIC12F675_PROG_TOOL PIC12F675_READ_PROG \
	PIC12F675_TRIM_EVIDENCE PIC12F675_BENCH_RESULT PIC12F675_RELEASE_TAG

# This is the first Make query. The corresponding parse guard rejects
# unsupported release overrides, injected makefiles, and malformed canonical
# inventories without executing a selected toolchain or entering a recipe.
RELEASE_CONTRACT_VALID=$(mkv RELEASE_CONTRACT_VALID) \
	|| die "Makefile release configuration guard failed"
[ "$RELEASE_CONTRACT_VALID" = 1 ] \
	|| die "Makefile release configuration guard returned an invalid result"

# Read and validate both inventory statements before any tool/configuration
# query. Set comparisons alone erase duplicates, so cardinality and uniqueness
# are independent invariants and precede selected-versus-pinned equality.
RELEASE_IMAGES=$(mkv RELEASE_IMAGES)
RELEASE_SOAK_NAMES=$(mkv RELEASE_SOAK_NAMES)
RELEASE_IDENTITY_PINNED=$(mkv RELEASE_IDENTITY_PINNED)
RELEASE_IDENTITY_SELECTED=$(mkv RELEASE_IDENTITY_SELECTED)
RELEASE_IDENTITY_IMAGES=$(mkv RELEASE_IDENTITY_IMAGES)
RELEASE_IDENTITY_SOAKS=$(mkv RELEASE_IDENTITY_SOAKS)
for identity_var in RELEASE_IMAGES RELEASE_SOAK_NAMES \
		RELEASE_IDENTITY_PINNED RELEASE_IDENTITY_SELECTED \
		RELEASE_IDENTITY_IMAGES RELEASE_IDENTITY_SOAKS; do
	[ -n "${!identity_var// /}" ] \
		|| die "Makefile $identity_var is empty; the production release contract is unusable"
done

require_unique_inventory() {   # usage: require_unique_inventory LABEL COUNT VALUE
	local label=$1 expected=$2 value=$3 entry
	local -a entries=() duplicates=()
	local -A seen=()
	read -r -a entries <<<"$value"
	for entry in "${entries[@]}"; do
		if [ -n "${seen[$entry]+set}" ]; then
			duplicates+=("$entry")
		else
			seen[$entry]=1
		fi
	done
	[ "${#duplicates[@]}" -eq 0 ] \
		|| die "$label contains duplicate entries: ${duplicates[*]}"
	[ "${#entries[@]}" -eq "$expected" ] \
		|| die "$label contains ${#entries[@]} entries; expected exactly $expected"
}

# Report which member names a set gained and lost rather than printing both
# sets: one moved FW_BASE renames all 21 images, and the useful sentence is
# "these are extra, those are missing". Pure bash keeps this before external
# release-tool validation.
identity_set_drift() {   # usage: identity_set_drift LABEL PINNED SELECTED
	local label=$1 name status=0
	local -A want=() got=()
	local -a extra=() missing=()
	for name in $2; do want[$name]=1; done
	for name in $3; do got[$name]=1; done
	for name in "${!got[@]}"; do
		[ -n "${want[$name]:-}" ] || extra+=("$name")
	done
	for name in "${!want[@]}"; do
		[ -n "${got[$name]:-}" ] || missing+=("$name")
	done
	if [ "${#extra[@]}" -gt 0 ]; then
		log "  $label has ${#extra[@]} entries the pinned identity does not: $(printf '%s ' "${extra[@]}")"
		status=1
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		log "  $label is missing ${#missing[@]} pinned entries: $(printf '%s ' "${missing[@]}")"
		status=1
	fi
	return "$status"
}

read -r -a identity_pinned_fields <<<"$RELEASE_IDENTITY_PINNED"
read -r -a identity_selected_fields <<<"$RELEASE_IDENTITY_SELECTED"
[ "${#identity_pinned_fields[@]}" -eq "${#identity_selected_fields[@]}" ] \
	|| die "the pinned release identity lists ${#identity_pinned_fields[@]} fields but ${#identity_selected_fields[@]} were selected.
      RELEASE_IDENTITY_PINNED and RELEASE_IDENTITY_SELECTED must describe the same fields in the same order."

IDENTITY_DRIFT=()
IDENTITY_SET_DRIFT=0
for ((identity_i = 0; identity_i < ${#identity_pinned_fields[@]}; identity_i++)); do
	pinned_field=${identity_pinned_fields[identity_i]}
	selected_field=${identity_selected_fields[identity_i]}
	[ "$pinned_field" = "$selected_field" ] && continue
	identity_name=${pinned_field%%=*}
	[ "${selected_field%%=*}" = "$identity_name" ] \
		|| die "the pinned and selected release identity fields are not in the same order ($pinned_field vs $selected_field)."
	identity_origin=$(make -s --no-print-directory origin-"$identity_name" 2>/dev/null) \
		|| identity_origin=
	IDENTITY_DRIFT+=("$identity_name: pinned '${pinned_field#*=}', selected '${selected_field#*=}' (Make origin: ${identity_origin:-unknown})")
done

if [ "${#IDENTITY_DRIFT[@]}" -gt 0 ]; then
	log "Production release identity does not match the pinned Makefile declaration:"
	for identity_line in "${IDENTITY_DRIFT[@]}"; do log "  $identity_line"; done
	die "refusing to run a release under an overridden production identity.
      A release always means the reviewed identity that RELEASE_IDENTITY_PINNED declares:
      seven parts, 21 images, 18 soak combinations, one basename convention.
      Re-run with none of the variables above set. Build-directory and tool-path
      overrides are unaffected and remain available.
      Make origin names the channel a value arrived on -- 'command line' is an
      argument someone typed, 'environment' is an inherited export that appears
      in no command at all, and 'override' means the Makefile recomputed the
      variable from a caller's request (VARIANTS and PIC10F320_VARIANTS_ALL are
      filtered that way, so their request is what to withdraw)."
fi

require_unique_inventory RELEASE_IMAGES 21 "$RELEASE_IMAGES"
require_unique_inventory RELEASE_IDENTITY_IMAGES 21 "$RELEASE_IDENTITY_IMAGES"
require_unique_inventory RELEASE_SOAK_NAMES 18 "$RELEASE_SOAK_NAMES"
require_unique_inventory RELEASE_IDENTITY_SOAKS 18 "$RELEASE_IDENTITY_SOAKS"

identity_set_drift RELEASE_IMAGES "$RELEASE_IDENTITY_IMAGES" "$RELEASE_IMAGES" \
	|| IDENTITY_SET_DRIFT=1
identity_set_drift RELEASE_SOAK_NAMES "$RELEASE_IDENTITY_SOAKS" "$RELEASE_SOAK_NAMES" \
	|| IDENTITY_SET_DRIFT=1
if [ "${#IDENTITY_DRIFT[@]}" -gt 0 ] || [ "$IDENTITY_SET_DRIFT" -ne 0 ]; then
	die "refusing to run a release under an overridden production identity.
      A release always means the reviewed identity that RELEASE_IDENTITY_PINNED declares:
      seven parts, 21 images, 18 soak combinations, one basename convention.
      Re-run with none of the variables above set. Build-directory and tool-path
      overrides are unaffected and remain available.
      Make origin names the channel a value arrived on -- 'command line' is an
      argument someone typed, 'environment' is an inherited export that appears
      in no command at all, and 'override' means the Makefile recomputed the
      variable from a caller's request (VARIANTS and PIC10F320_VARIANTS_ALL are
      filtered that way, so their request is what to withdraw)."
fi
read -r -a identity_pinned_images <<<"$RELEASE_IDENTITY_IMAGES"
read -r -a identity_pinned_soaks <<<"$RELEASE_IDENTITY_SOAKS"
ok "production release identity matches the pinned declaration: ${#identity_pinned_fields[@]} fields, ${#identity_pinned_images[@]} images, ${#identity_pinned_soaks[@]} soak combinations."

AWK=$(mkv AWK)
AWK=$(tool_from_repo "$AWK")

VARIANTS=$(mkv VARIANTS)           # cd4053_simple cd4053_with_mute tq2_l2_5v_relay
TINYX5=$(mkv TINYX5)               # 85 45      (the family's internal indexing)
TINYX5_PARTS=$(mkv TINYX5_PARTS)   # attiny85 attiny45  (what a request names)
FW_BASE=$(mkv FW_BASE)             # bypass
ATTINY13A_MCU=$(mkv ATTINY13A_MCU) # attiny13a

# The canonical image basename: <prefix>-<mcu>-<output stage>, where the stage
# field IS the variant name. Composed here rather than read back from the
# Makefile ON PURPOSE: the enumeration below is this script's INDEPENDENT
# opinion of what a complete release contains, and it is cross-checked against
# the Makefile's RELEASE_IMAGES a few dozen lines down. Deriving the names from
# the thing being cross-checked would make that check agree with itself.
#
# v0.9.8 briefly needed a variant->stage translation table here. It is gone
# because the vocabularies were unified rather than mapped, so the only thing
# left to restate is the delimiter layout.
# $(fw_image <build dir> <mcu tag> <variant>) -> full path, no suffix
fw_image() { printf '%s/%s-%s-%s' "$1" "$FW_BASE" "$2" "$3"; }
AVR_BUILD_DIR=$(mkv AVR_BUILD_DIR) # build_avr_classic
PIC10F322_BUILD_DIR=$(mkv PIC10F322_BUILD_DIR) # build_pic10f322
PIC10F322_TAG=$(mkv PIC10F322_TAG)             # pic10f322
PIC10F322_XTAL=$(mkv PIC10F322_XTAL)           # 2000000UL  (_XTAL_FREQ; drives __delay_ms)
# The manifest clock string is derived after preflight validates the selected
# AWK, so it cannot drift from this firmware clock source.
PIC10F322_GPSIM_PROC=$(mkv PIC10F322_GPSIM_PROC)
LFUSE=$(mkv ATTINY13A_LFUSE);     HFUSE=$(mkv ATTINY13A_HFUSE)
LFUSE_X5=$(mkv TINYX5_LFUSE); HFUSE_X5=$(mkv TINYX5_HFUSE)
PIC_CC=$(mkv PIC_CC)
PIC_DFP=$(mkv PIC_DFP)
PIC_CC=$(tool_from_repo "$PIC_CC")
PIC_DFP=$(path_from_repo "$PIC_DFP")
AVRDUDE_PART=$(mkv ATTINY13A_AVRDUDE_PART)   # t13
declare -A AVRDUDE_PART_X5
for n in $TINYX5; do AVRDUDE_PART_X5[$n]=$(mkv part_"$n"); done

# --- ATtiny202 (AVR-XT) ------------------------------------------------------
# Read through its own variables for the same reason the PIC pair below does:
# the AVR-XT shares avr-gcc with the classic parts but nothing else -- its own
# device pack, its own clock, its own fuse model (seven named AVR8X memories
# rather than lfuse/hfuse), and a simulator that is neither simavr nor gpsim.
XT_BUILD_DIR=$(mkv XT_BUILD_DIR)   # build_avr_xt
XT_TAG=$(mkv XT_TAG)               # attiny202
XT_MCU=$(mkv XT_MCU)               # attiny202
XT_DFP=$(mkv XT_DFP)               # third_party/attiny_dfp
XT_DFP=$(path_from_repo "$XT_DFP")
XT_F_CPU=$(mkv XT_F_CPU)           # 2000000UL
XT_FLASH_BYTES=$(mkv XT_FLASH_BYTES)
XT_VARIANTS=$(mkv XT_VARIANTS_SUPPORTED)     # same three names as VARIANTS
YASIMAVR_PY=$(mkv YASIMAVR_PY)     # third_party/yasimavr/venv/bin/python
YASIMAVR_PY_ABS=$(path_from_repo "$YASIMAVR_PY")
XT_AVRDUDE_PART=$(mkv XT_AVRDUDE_PART)       # t202
XT_PROGRAMMER=$(mkv XT_PROGRAMMER)           # serialupdi
# The seven AVR8X fuse bytes, in the datasheet's memory order. Unlike the classic
# parts' lfuse/hfuse pair these are individually named avrdude memories, so the
# manifest and the flashing recipe both have to enumerate them.
XT_FUSE_NAMES="wdtcfg bodcfg osccfg syscfg0 syscfg1 append bootend"
declare -A XT_FUSE
XT_FUSE[wdtcfg]=$(mkv XT_FUSE_WDTCFG)
XT_FUSE[bodcfg]=$(mkv XT_FUSE_BODCFG)
XT_FUSE[osccfg]=$(mkv XT_FUSE_OSCCFG)
XT_FUSE[syscfg0]=$(mkv XT_FUSE_SYSCFG0)
XT_FUSE[syscfg1]=$(mkv XT_FUSE_SYSCFG1)
XT_FUSE[append]=$(mkv XT_FUSE_APPEND)
XT_FUSE[bootend]=$(mkv XT_FUSE_BOOTEND)

# --- PIC10F320, the constrained release target -------------------------------
# Read through its OWN variables, never by deriving from the PIC10F322's. The
# two chips share one XC8 + DFP installation today, but the separate variable
# pairs exist precisely so one can be re-pinned (merge plan §5.6) -- and a
# release script that assumed they track would build one chip with the other's
# toolchain and say nothing.
PIC10F320_BUILD_DIR=$(mkv PIC10F320_BUILD_DIR)     # build_pic10f320
PIC10F320_TAG=$(mkv PIC10F320_TAG)                 # pic10f320
PIC10F320_VARIANTS=$(mkv PIC10F320_VARIANTS_ALL)   # same three names as VARIANTS
PIC10F320_XTAL=$(mkv PIC10F320_XTAL)
PIC10F320_FLASH_WORDS=$(mkv PIC10F320_FLASH_WORDS) # 256
PIC10F320_CC=$(mkv PIC10F320_CC)
PIC10F320_DFP=$(mkv PIC10F320_DFP)
PIC10F320_CC=$(tool_from_repo "$PIC10F320_CC")
PIC10F320_DFP=$(path_from_repo "$PIC10F320_DFP")

# --- PIC12F675, the classic mid-range release target -------------------------
# Read through its OWN variables, like the two 10F32x parts. It shares this
# repo's PIC_CC/PIC_DFP install with the PIC10F322 -- one XC8 + one DFP serve all
# three PICs today -- but its geometry, clock, CONFIG map and, uniquely, its
# DERIVED simulator image are its own. The soak drives that derived "simcal"
# image (the shipped HEX with a fabricated oscillator-calibration word injected
# into flash word 0x3FF), never the shipped HEX itself, so this part is threaded
# like the ATtiny202 above: a shipped artifact (HEX) and a distinct soaked
# artifact (the simcal HEX), each hashed and checked in its own array, bound
# together by the pic12f675-test-calibration gate that runs in section 2.
PIC12F675_BUILD_DIR=$(mkv PIC12F675_BUILD_DIR)     # build_pic12f675
PIC12F675_TAG=$(mkv PIC12F675_TAG)                 # pic12f675
PIC12F675_XTAL=$(mkv PIC12F675_XTAL)               # 4000000UL
PIC12F675_FLASH_WORDS=$(mkv PIC12F675_FLASH_WORDS) # 1024
PIC12F675_GPSIM_PROC=$(mkv PIC12F675_GPSIM_PROC)   # p12f675
PIC12F675_SIMCAL_DIR=$(mkv PIC12F675_SIMCAL_DIR)   # build_pic12f675/simcal
PIC12F675_MATRIX_EVIDENCE=$(mkv PIC12F675_MATRIX_EVIDENCE)
PIC12F675_MATRIX_MANIFEST=$(mkv PIC12F675_MATRIX_MANIFEST)
PIC12F675_PYTHON=$(mkv PIC12F675_PYTHON)
PIC12F675_MATRIX_EVIDENCE=$(path_from_repo "$PIC12F675_MATRIX_EVIDENCE")
PIC12F675_MATRIX_MANIFEST=$(path_from_repo "$PIC12F675_MATRIX_MANIFEST")
PIC12F675_PYTHON=$(tool_from_repo "$PIC12F675_PYTHON")

# --- host / AVR / analysis tools, read through their Makefile variables -------
# The preconditions below assert these, and the manifest records their versions.
# Both must name the tool the BUILD will actually run: every one of these is a
# Makefile variable (`?=` for most, so the environment wins), so a hardcoded
# `clang` here would assert one binary while `make` used another -- passing a
# release whose analysis never ran, or failing one whose toolchain is merely
# installed elsewhere. This is the reasoning the PIC pairs above already embody.
HOST_CC=$(mkv HOSTCC)
AVR_CC=$(mkv CC)
AVR_OBJCOPY=$(mkv OBJCOPY)
AVR_SIZE=$(mkv SIZE)
AVR_OBJDUMP=$(mkv OBJDUMP)
READELF=$(mkv READELF)
IHEX_VALIDATOR=$(mkv IHEX_VALIDATOR)
CLANG=$(mkv CLANG)
CPPCHECK=$(mkv CPPCHECK)
CBMC=$(mkv CBMC)
GCOV=$(mkv GCOV)
GPSIM=$(mkv GPSIM)
SIMAVR_INC=$(mkv SIMAVR_INC)
PIC_XC8_INCLUDE=$(mkv PIC_XC8_INCLUDE)
PIC10F320_XC8_INCLUDE=$(mkv PIC10F320_XC8_INCLUDE)
PIC10F322_DFP_INCLUDE=$(mkv PIC10F322_DFP_INCLUDE)
PIC10F320_DFP_INCLUDE=$(mkv PIC10F320_DFP_INCLUDE)
PIC10F322_DEVICE_INI=$(mkv PIC10F322_DEVICE_INI)
PIC10F320_DEVICE_INI=$(mkv PIC10F320_DEVICE_INI)
PIC12F675_DFP_INCLUDE=$(mkv PIC12F675_DFP_INCLUDE)
PIC12F675_DEVICE_INI=$(mkv PIC12F675_DEVICE_INI)
XT_IO_HEADER=$(mkv XT_IO_HEADER)
PIC10F320_HOST_CC=$(mkv PIC10F320_HOST_CC)
PIC_SOAK_CXX=$(mkv PIC_SOAK_CXX)
PIC10F320_SOAK_CXX=$(mkv PIC10F320_SOAK_CXX)
PIC_SOAK_GPSIM_INC=$(mkv PIC_SOAK_GPSIM_INC)
PIC10F320_SOAK_GPSIM_INC=$(mkv PIC10F320_SOAK_GPSIM_INC)
ANALYZE_CMD=$(mkv ANALYZE_CMD)

SIMAVR_INC=$(path_from_repo "$SIMAVR_INC")
PIC_XC8_INCLUDE=$(path_from_repo "$PIC_XC8_INCLUDE")
PIC10F320_XC8_INCLUDE=$(path_from_repo "$PIC10F320_XC8_INCLUDE")
PIC10F322_DFP_INCLUDE=$(path_from_repo "$PIC10F322_DFP_INCLUDE")
PIC10F320_DFP_INCLUDE=$(path_from_repo "$PIC10F320_DFP_INCLUDE")
PIC10F322_DEVICE_INI=$(path_from_repo "$PIC10F322_DEVICE_INI")
PIC10F320_DEVICE_INI=$(path_from_repo "$PIC10F320_DEVICE_INI")
PIC12F675_DFP_INCLUDE=$(path_from_repo "$PIC12F675_DFP_INCLUDE")
PIC12F675_DEVICE_INI=$(path_from_repo "$PIC12F675_DEVICE_INI")
XT_IO_HEADER=$(path_from_repo "$XT_IO_HEADER")
PIC_SOAK_GPSIM_INC=$(path_from_repo "$PIC_SOAK_GPSIM_INC")
PIC10F320_SOAK_GPSIM_INC=$(path_from_repo "$PIC10F320_SOAK_GPSIM_INC")
AVR_CC=$(tool_from_repo "$AVR_CC")
AVR_OBJCOPY=$(tool_from_repo "$AVR_OBJCOPY")
AVR_SIZE=$(tool_from_repo "$AVR_SIZE")
AVR_OBJDUMP=$(tool_from_repo "$AVR_OBJDUMP")
READELF=$(tool_from_repo "$READELF")
IHEX_VALIDATOR=$(tool_from_repo "$IHEX_VALIDATOR")
HOST_CC=$(tool_from_repo "$HOST_CC")
PIC10F320_HOST_CC=$(tool_from_repo "$PIC10F320_HOST_CC")
CLANG=$(tool_from_repo "$CLANG")
CPPCHECK=$(tool_from_repo "$CPPCHECK")
CBMC=$(tool_from_repo "$CBMC")
GCOV=$(tool_from_repo "$GCOV")
GPSIM=$(tool_from_repo "$GPSIM")
PIC_SOAK_CXX=$(tool_from_repo "$PIC_SOAK_CXX")
PIC10F320_SOAK_CXX=$(tool_from_repo "$PIC10F320_SOAK_CXX")
ANALYZE_TOOL=${ANALYZE_CMD%%[[:space:]]*}
AVR_NM=$(tool_from_repo "${AVR_NM:-avr-nm}")
MUTATION_MAKE=$(tool_from_repo "${MUTATION_MAKE:-make}")

# Every nested Make and child script must consume the exact paths preflight
# approved. Most Makefile selectors are ?= and therefore honor these exports;
# the three plain classic-tool assignments are also passed explicitly where the
# release invokes their build/test graphs.
export OBJDUMP="$AVR_OBJDUMP" READELF IHEX_VALIDATOR AWK HOSTCC="$HOST_CC"
export CLANG CPPCHECK CBMC GCOV GPSIM SIMAVR_INC
export ANALYZE_CMD AVR_NM MUTATION_MAKE
export PIC_CC PIC_DFP PIC_XC8_INCLUDE PIC10F322_DFP_INCLUDE PIC10F322_DEVICE_INI
export PIC10F320_CC PIC10F320_DFP PIC10F320_XC8_INCLUDE PIC10F320_DFP_INCLUDE PIC10F320_DEVICE_INI
export PIC12F675_DFP_INCLUDE PIC12F675_DEVICE_INI
export PIC12F675_PYTHON
export PIC10F320_HOST_CC PIC_SOAK_CXX PIC10F320_SOAK_CXX
export PIC_SOAK_GPSIM_INC PIC10F320_SOAK_GPSIM_INC XT_DFP
export YASIMAVR_VENV="$(dirname "$(dirname "$YASIMAVR_PY_ABS")")"

# The canonical release product set (merge plan §10). This script ENUMERATES the
# images it expects to build from the variant matrices below; RELEASE_IMAGES is
# the independent statement of what a complete release contains, and the two are
# cross-checked before anything is staged. Enumeration alone cannot catch a
# missing build step -- it would simply enumerate fewer images and agree with
# itself, which is the whole failure mode §14.8 describes.
# The build directories those images come from, so the reproduction instructions
# this script GENERATES cannot list a stale set of directories.
RELEASE_IMAGE_DIRS=$(mkv RELEASE_IMAGE_DIRS)
[ -n "${RELEASE_IMAGE_DIRS// /}" ] \
	|| die "Makefile RELEASE_IMAGE_DIRS is empty"
RELEASE_EVIDENCE_FILES=$(mkv RELEASE_EVIDENCE_FILES)
[ -n "${RELEASE_EVIDENCE_FILES// /}" ] \
	|| die "Makefile RELEASE_EVIDENCE_FILES is empty"
# Required release artifacts that are NOT firmware images: <staged basename>=
# <tracked source>. Declared separately from RELEASE_IMAGES so shipping a tool
# beside the images cannot move the reviewed image count, and validated here so
# a missing or misdeclared source fails before a 24-hour soak, not after it.
RELEASE_HELPER_MAP=$(mkv RELEASE_HELPER_MAP)
[ -n "${RELEASE_HELPER_MAP// /}" ] \
	|| die "Makefile RELEASE_HELPER_MAP is empty; a release must declare its required non-image artifacts"
declare -A RELEASE_HELPER_SOURCE=()
RELEASE_HELPER_NAMES=()
for helper_entry in $RELEASE_HELPER_MAP; do
	helper_base=${helper_entry%%=*}
	helper_src=${helper_entry#*=}
	[ -n "$helper_base" ] && [ -n "$helper_src" ] && [ "$helper_base" != "$helper_entry" ] \
		|| die "malformed RELEASE_HELPER_MAP entry: $helper_entry"
	case "$helper_base" in
		*/*|.*|*.hex) die "invalid staged name for a required release artifact: $helper_base" ;;
	esac
	[ -z "${RELEASE_HELPER_SOURCE[$helper_base]+set}" ] \
		|| die "duplicate required release artifact: $helper_base"
	[ -f "$REPO_ROOT/$helper_src" ] && [ ! -L "$REPO_ROOT/$helper_src" ] \
		&& [ -s "$REPO_ROOT/$helper_src" ] \
		|| die "required release artifact source is missing or not a regular file: $helper_src"
	RELEASE_HELPER_SOURCE[$helper_base]=$helper_src
	RELEASE_HELPER_NAMES+=("$helper_base")
done

# A production or versioned rehearsal must start from finalized release prose.
# Validate before scratch creation so a stale declaration cannot consume tools,
# build an image, or leave a release work directory behind.
if [ "$VERSION_WAS_SUPPLIED" -eq 1 ]; then
	read -r -a DOCUMENT_RELEASE_IMAGES <<<"$RELEASE_IMAGES"
	read -r -a DOCUMENT_RELEASE_SOAKS <<<"$RELEASE_SOAK_NAMES"
	ALLOW_UNRELEASED=$PREFLIGHT
	release_validate_current_documentation "$REPO_ROOT" "$VERSION" \
		"${#DOCUMENT_RELEASE_IMAGES[@]}" "${#DOCUMENT_RELEASE_SOAKS[@]}" \
		"$ALLOW_UNRELEASED" \
		|| die "current release documentation is not finalized for $VERSION"
	# Published recovery instructions must actually recover the transaction the
	# published programming command reserves. Checked here, on the live tree, so
	# a drifted static example fails on a polish branch rather than after a
	# builder has already lost a PENDING signed-release transaction.
	release_validate_pic12f675_finalization "$REPO_ROOT" "$VERSION" \
		|| die "published PIC12F675 finalization commands do not match the transaction they recover"
	# Field use and controlled qualification are different claims, and this
	# repository holds only the first. Checked here, on the live tree, so a
	# document that promotes a forum build report into bench evidence -- or that
	# denies the field use outright -- fails during branch work rather than in a
	# release that then reads as qualified hardware.
	release_validate_hardware_claims "$REPO_ROOT" \
		|| die "hardware evidence is not correctly classified as field use or controlled qualification"
	# The PIC12F675 is not a raw write target, and the release that says so must
	# also ship the tool that replaces the raw command. Checked here, on the live
	# tree, so a document that reinstates a raw writer -- or a release that
	# instructs an operator to use a helper it does not bundle -- fails during
	# branch work rather than after someone has erased a device's factory trim.
	release_validate_pic12f675_flashing_helper "$REPO_ROOT" "$VERSION" \
		|| die "published PIC12F675 flashing instructions do not match the release-shipped helper contract"
	# A preserved design discussion whose proposals have since shipped must say
	# so where a reader stops -- its status banner -- and at each proposal that
	# landed. Checked here, on the live tree, so the banner is reconciled on the
	# branch that implements a proposal rather than left denying it in a release.
	release_validate_flashing_simplicity_status "$REPO_ROOT" \
		|| die "the flashing-simplicity design document contradicts its own implementation updates"
fi

# Scratch area for evidence + per-combo soak run dirs. Preserved on failure so a
# crashed/failed run can be inspected; folded into the release on success.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcu-release.XXXXXX")"
EVID="$WORK/evidence"; SOAKDIR="$WORK/soak"
KEEP_WORK=0
SOAK_PIDS=()
TRACKING_WORKER=0
PENDING_SIGNAL_STATUS=0
cleanup() { [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"; }
on_exit() {
	local rc=$?
	trap - EXIT
	# Cleanup is now the only path to a safe exit. Ignore repeated signals until
	# every isolated worker group has been killed and its direct child reaped.
	trap '' HUP INT TERM
	if ! release_terminate_workers "${SOAK_PIDS[@]}"; then
		rc=1
		warn "could not terminate every release soak worker cleanly"
	fi
	SOAK_PIDS=()
	if [ "$rc" -ne 0 ] && [ "${PREFLIGHT:-0}" -eq 0 ]; then
		KEEP_WORK=1
		warn "left working dir for inspection: $WORK"
	fi
	cleanup
	exit "$rc"
}
on_signal() {
	local status=$1
	if [ "${TRACKING_WORKER:-0}" -eq 1 ]; then
		PENDING_SIGNAL_STATUS=$status
		return
	fi
	exit "$status"
}
trap on_exit EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
mkdir -p "$EVID" "$SOAKDIR" \
	|| die "could not initialize release scratch directories under $WORK"

# Where to stage. A real release lands in the repo at release/<version>; a dry
# run lands in the auto-scratch WORK (kept, never littering the repo).
if [ -n "$OUTPUT_DIR" ]; then :;
elif [ "$DRY_RUN" -eq 1 ]; then OUTPUT_DIR="$WORK/release/$VERSION"; KEEP_WORK=1
else OUTPUT_DIR="release/$VERSION"
fi
release_output_path_is_safe "$REPO_ROOT" "$OUTPUT_DIR" "$RELEASE_MODE" "$VERSION"

# ============================================================================
# 0. PRECONDITIONS
# ============================================================================
section "0. preconditions"

# Clean working tree -- the provenance commit SHA must mean something. A real
# release requires it; explicitly non-publishable dry-run and capability-only
# preflight modes warn because they are intended to run before the release
# changes are committed.
GIT_DIRTY=0
if ! GIT_STATUS=$(git status --porcelain); then
	die "could not inspect working-tree status"
fi
if [ -n "$GIT_STATUS" ]; then
	GIT_DIRTY=1
	if [ "$DRY_RUN" -eq 1 ] || [ "$PREFLIGHT" -eq 1 ]; then
		warn "working tree is DIRTY; provenance SHA $(git rev-parse --short HEAD) will not capture uncommitted changes."
	else
		git status --short >&2
		die "working tree is not clean. Commit/stash everything before releasing (or --dry-run to rehearse)."
	fi
fi

# Tag availability is publishing state, not host capability. Check and warn in
# preflight when a real prospective version was supplied; with no version there
# is intentionally nothing meaningful to query.
if [ "$PREFLIGHT" -eq 1 ] && [ "$VERSION_WAS_SUPPLIED" -eq 0 ]; then
	warn "no release version supplied; tag availability was not checked."
else
	if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
		LOCAL_TAG_STATUS=0
	else
		LOCAL_TAG_STATUS=$?
	fi
	case "$LOCAL_TAG_STATUS" in
		0)
			[ "$PREFLIGHT" -eq 1 ] && warn "tag $VERSION already exists locally." \
				|| die "tag $VERSION already exists."
			;;
		1) : ;; # no matching local ref
		*)
			[ "$PREFLIGHT" -eq 1 ] \
				&& warn "could not check local tag $VERSION (git rev-parse exited $LOCAL_TAG_STATUS)." \
				|| die "could not check local tag $VERSION (git rev-parse exited $LOCAL_TAG_STATUS)."
			;;
	esac
	if git remote get-url origin >/dev/null 2>&1; then
		ORIGIN_STATUS=0
	else
		ORIGIN_STATUS=$?
	fi
	case "$ORIGIN_STATUS" in
	0)
		if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
			REMOTE_TAG_STATUS=0
		else
			REMOTE_TAG_STATUS=$?
		fi
		case "$REMOTE_TAG_STATUS" in
			0)
				[ "$PREFLIGHT" -eq 1 ] && warn "tag $VERSION already exists on origin." \
					|| die "tag $VERSION already exists on origin."
				;;
			2) : ;; # --exit-code: remote reachable, no matching ref
			*)
				[ "$PREFLIGHT" -eq 1 ] \
					&& warn "could not check tag $VERSION on origin (git ls-remote exited $REMOTE_TAG_STATUS)." \
					|| die "could not check tag $VERSION on origin (git ls-remote exited $REMOTE_TAG_STATUS)."
				;;
		esac
		;;
	2) : ;; # no origin configured
	*)
		[ "$PREFLIGHT" -eq 1 ] \
			&& warn "could not inspect origin for tag $VERSION (git remote get-url exited $ORIGIN_STATUS)." \
			|| die "could not inspect origin for tag $VERSION (git remote get-url exited $ORIGIN_STATUS)."
		;;
	esac
fi

# Output dir must not already exist (don't clobber a prior release).
OUTPUT_EXISTS=0
if [ -e "$OUTPUT_DIR" ]; then
	OUTPUT_EXISTS=1
	[ "$PREFLIGHT" -eq 1 ] && warn "$OUTPUT_DIR already exists; a real release would refuse to overwrite it." \
		|| die "$OUTPUT_DIR already exists; refusing to overwrite."
fi

GIT_SHA=$(git rev-parse HEAD)
GIT_SHORT=$(git rev-parse --short HEAD)

# Required tools. A release FAILS LOUD on any absence (no silent skipping).
MISSING=()
have()      { command -v "$1" >/dev/null 2>&1; }
req_cmd()   { have "$1" || MISSING+=("$1${2:+  ($2)}"); }
req_file()  { [ -f "$1" ] && [ -s "$1" ] || MISSING+=("$1${2:+  ($2)}"); }
req_exec() {
	case "$1" in
		*/*) [ -f "$1" ] && [ -s "$1" ] && [ -x "$1" ] ;;
		*)   have "$1" ;;
	esac || MISSING+=("$1${2:+  ($2)}")
}
req_exec_file() {
	[ -f "$1" ] && [ -s "$1" ] && [ -x "$1" ] \
		|| MISSING+=("$1${2:+  ($2)}")
}

req_cmd git           "repository provenance and tag validation"
req_cmd make          "release configuration and qualification orchestration"
req_cmd flock          "apt: util-linux (whole-worktree serialization)"
req_cmd setsid         "apt: util-linux (isolated release-soak process groups)"
req_cmd ps             "apt: procps (mutation checker-session cleanup)"
req_cmd "$AVR_CC"      "apt: gcc-avr"
req_cmd "$AVR_OBJCOPY" "apt: binutils-avr (HEX bytes + reproducibility)"
req_cmd "$AVR_SIZE"    "apt: binutils-avr"
req_cmd "$AVR_OBJDUMP" "apt: binutils-avr (ATtiny202 coil-pulse width oracle)"
req_cmd "$READELF"     "apt: binutils (ELF architecture validation)"
req_exec_file "$IHEX_VALIDATOR" "nonempty executable Intel HEX validator file (IHEX_VALIDATOR=)"
req_cmd "$AWK"         "awk implementation selected by AWK"
if have "$AWK" && [ "$("$AWK" 'BEGIN { print "release-awk-ok" }' 2>/dev/null)" != release-awk-ok ]; then
	MISSING+=("$AWK  (AWK must execute a basic program and produce output)")
fi
req_cmd "$HOST_CC"     "host C compiler (HOSTCC=)"
req_cmd "$PIC10F320_HOST_CC" "PIC10F320 host compiler selected by PIC10F320_HOST_CC"
req_cmd "$ANALYZE_TOOL" "analysis command selected by ANALYZE_CMD"
req_cmd "$AVR_NM"      "ATtiny202 symbol resolver selected by AVR_NM"
req_cmd "$MUTATION_MAKE" "Make executable selected by MUTATION_MAKE"
req_file "$SIMAVR_INC/sim_avr.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/sim_elf.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/sim_irq.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/sim_vcd_file.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/avr_ioport.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_cmd "$CLANG"       "apt: clang (analyze-deep)"
req_cmd "$CPPCHECK"    "apt: cppcheck (analyze + MISRA)"
req_cmd "$CBMC"        "apt: cbmc (formal proof in test-long)"
req_cmd python3        "Python 3.7 or newer; host gates and MISRA addon"
req_exec "$PIC12F675_PYTHON" "PIC12F675 helper interpreter selected by PIC12F675_PYTHON"
PYTHON_VERSION_OK=0
if have python3; then
	if PYTHON_VERSION_ERROR=$(python3 "$REPO_ROOT/test/python_version.py" 2>&1); then
		PYTHON_VERSION_OK=1
	else
		MISSING+=("${PYTHON_VERSION_ERROR:-python3 minimum-version probe failed}")
	fi
fi
if have "$PIC12F675_PYTHON" \
		&& ! "$PIC12F675_PYTHON" "$REPO_ROOT/test/python_version.py" >/dev/null 2>&1; then
	MISSING+=("$PIC12F675_PYTHON  (PIC12F675_PYTHON must select Python 3.7 or newer)")
fi
if [ "$PYTHON_VERSION_OK" -eq 1 ] \
		&& ! python3 -c 'import yaml' >/dev/null 2>&1; then
	MISSING+=("PyYAML  (apt: python3-yaml; strict workflow syntax validation)")
fi
req_cmd gpg            "release checksum/tag signing and signature regressions"
req_cmd timeout        "coreutils (bounded mutation and simulator probes)"
req_cmd tar            "tar (PIC10F320 coverage archive regression)"
# gcov backs coverage-check / coverage-check-core, which run inside the
# `make test-long` at step 2. Absent, that gate fails AFTER the clean build.
req_cmd "$GCOV"        "ships with gcc (coverage-check in test-long)"
# sha256sum is the release's trust anchor: it hashes the validated image set and
# writes SHA256SUMS during STAGING -- i.e. on the far side of the 24-hour soak.
# Nothing before that point would notice its absence.
req_cmd sha256sum      "coreutils (SHA256SUMS; the reproducibility anchor)"
if have "$AVR_CC" && ! printf '%s\n' \
		'#include <avr/io.h>' '#include <avr/wdt.h>' '#include <avr/power.h>' \
		'#include <avr/sleep.h>' '#include <avr/interrupt.h>' \
		| "$AVR_CC" -mmcu="$ATTINY13A_MCU" -x c -E - >/dev/null 2>&1; then
	MISSING+=("avr-libc headers  (apt: avr-libc; selected CC cannot preprocess the firmware headers)")
fi
if have "$HOST_CC" && ! printf '%s\n' \
		'#include "sim_avr.h"' '#include "sim_elf.h"' '#include "sim_irq.h"' \
		'#include "sim_vcd_file.h"' '#include "avr_ioport.h"' \
		'int main(void) { return 0; }' \
		| "$HOST_CC" -std=c11 -I"$SIMAVR_INC" -x c - -o "$WORK/preflight-simavr-link" \
			-Wl,--no-as-needed -lsimavr -lelf >/dev/null 2>&1; then
	MISSING+=("simavr header/link capability  (apt: libsimavr-dev libelf-dev; SIMAVR_INC=, HOSTCC=)")
fi
# PIC toolchain (paths come from the Makefile defaults / PIC_CC, PIC_DFP).
req_exec "$PIC_CC"                                  "executable XC8 driver (PIC_CC=)"
req_file "$PIC_DFP/pic/include/proc/pic10f322.h"    "PIC10-12Fxxx DFP (PIC_DFP=)"
req_file "$PIC_XC8_INCLUDE/xc.h"                    "XC8 base header (PIC_XC8_INCLUDE=)"
req_file "$PIC10F322_DFP_INCLUDE/proc/pic10f322.h"  "PIC10F322 analysis header (PIC10F322_DFP_INCLUDE=)"
req_file "$PIC10F322_DEVICE_INI"                    "PIC10F322 device geometry (PIC10F322_DEVICE_INI=)"
# ...and the PIC10F320's, asserted through its own pair. One DFP ships both
# device headers, so this normally passes with the line above -- but a truncated
# unpack, or a deliberately re-pinned PIC10F320_DFP, is exactly the case where the
# 320 lane would otherwise skip cleanly and the release would ship 15 images
# while claiming 18.
req_exec "$PIC10F320_CC"                                "executable XC8 driver (PIC10F320_CC=)"
req_file "$PIC10F320_DFP/pic/include/proc/pic10f320.h"  "PIC10F320 device header (PIC10F320_DFP=)"
req_file "$PIC10F320_XC8_INCLUDE/xc.h"                   "XC8 base header (PIC10F320_XC8_INCLUDE=)"
req_file "$PIC10F320_DFP_INCLUDE/proc/pic10f320.h"       "PIC10F320 analysis header (PIC10F320_DFP_INCLUDE=)"
req_file "$PIC10F320_DEVICE_INI"                        "PIC10F320 device geometry (PIC10F320_DEVICE_INI=)"
# ...and the PIC12F675's, through its own analysis pair and the shared DFP. Same
# reasoning as the 320 above: one DFP ships all three device headers, so a
# truncated unpack (or a re-pinned include) is the case where this lane would
# otherwise skip cleanly and the release would ship 18 images while claiming 21.
# The build shares PIC_CC/PIC_DFP, asserted above; the soak reuses PIC_SOAK_CXX
# and PIC_SOAK_GPSIM_INC, also asserted above, so only the analysis inputs are new.
req_file "$PIC_DFP/pic/include/proc/pic12f675.h"        "PIC12F675 device header (PIC_DFP=)"
req_file "$PIC12F675_DFP_INCLUDE/proc/pic12f675.h"      "PIC12F675 analysis header (PIC12F675_DFP_INCLUDE=)"
req_file "$PIC12F675_DEVICE_INI"                        "PIC12F675 device geometry (PIC12F675_DEVICE_INI=)"
req_cmd "$GPSIM"       "apt: gpsim (pic10f322-test-gpsim, pic10f320-test-gpsim)"
req_cmd "$PIC_SOAK_CXX"       "host C++ compiler selected by PIC_SOAK_CXX"
req_cmd "$PIC10F320_SOAK_CXX" "host C++ compiler selected by PIC10F320_SOAK_CXX"
# Each chip's libgpsim headers through its OWN variable, for the same reason the
# CC/DFP pairs above are: one gpsim-dev install serves both today, but the two
# variables exist so one lane can be re-pinned, and a single hardcoded path
# would assert the wrong install and let the other lane skip.
for gpsim_header in interface.h sim_context.h processor.h pic-processor.h modules.h ioports.h stimuli.h \
		gpsim_time.h breakpoints.h trigger.h registers.h; do
	req_file "$PIC_SOAK_GPSIM_INC/$gpsim_header" \
		"apt: gpsim-dev (PIC10F322 gates; PIC_SOAK_GPSIM_INC=)"
	req_file "$PIC10F320_SOAK_GPSIM_INC/$gpsim_header" \
		"apt: gpsim-dev (PIC10F320 gates; PIC10F320_SOAK_GPSIM_INC=)"
done
req_cmd pkg-config     "apt: pkg-config (PIC soak glib flags)"
if have pkg-config && pkg-config --exists glib-2.0 2>/dev/null; then
	if GLIB_CFLAGS_RAW=$(pkg-config --cflags glib-2.0 2>/dev/null); then
		read -r -a GLIB_CFLAGS <<< "$GLIB_CFLAGS_RAW"
	else
		MISSING+=("glib-2.0 compiler flags  (pkg-config --cflags glib-2.0 failed)")
		GLIB_CFLAGS=()
	fi
	for gpsim_probe in \
		"PIC10F322|$PIC_SOAK_CXX|$PIC_SOAK_GPSIM_INC" \
		"PIC10F320|$PIC10F320_SOAK_CXX|$PIC10F320_SOAK_GPSIM_INC"; do
		IFS='|' read -r gpsim_label gpsim_cxx gpsim_inc <<< "$gpsim_probe"
		if have "$gpsim_cxx" && ! printf '%s\n' \
				'#include <glib.h>' '#include "gpsim_time.h"' '#include "breakpoints.h"' \
				'#include "trigger.h"' '#include "registers.h"' \
				'#include "pic/gpsim_bootstrap.h"' 'int main() { return 0; }' \
				| "$gpsim_cxx" -std=c++17 "${GLIB_CFLAGS[@]}" \
					-isystem "$gpsim_inc" -I"$REPO_ROOT/test" -I"$REPO_ROOT/src" \
					-x c++ - -o "$WORK/preflight-gpsim-$gpsim_label" \
					-Wl,--no-as-needed -lgpsim >/dev/null 2>&1; then
			MISSING+=("$gpsim_label gpsim compile/link capability  (gpsim-dev + libglib2.0-dev)")
		fi
	done
else
	MISSING+=("glib-2.0  (apt: libglib2.0-dev, PIC soaks)")
fi
# ATtiny202 (AVR-XT). Both inputs are fetched on demand and NOT committed, and
# every attiny202-* target skips cleanly without them -- so a release that did
# not assert them here would quietly ship three unqualified images. avr-nm and
# avr-objdump are the harness's own tools: the drivers resolve ctx_ with the
# former and read coil-pulse widths back out of the image with the latter.
req_file "$XT_DFP/gcc/dev/$XT_MCU/device-specs/specs-$XT_MCU" \
	"ATtiny_DFP (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_file "$XT_DFP/gcc/dev/$XT_MCU/avrxmega3/short-calls/crt$XT_MCU.o" \
	"ATtiny_DFP C runtime (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_file "$XT_DFP/gcc/dev/$XT_MCU/avrxmega3/short-calls/lib$XT_MCU.a" \
	"ATtiny_DFP device library (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_file "$XT_IO_HEADER" "ATtiny_DFP I/O header (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_exec "$YASIMAVR_PY_ABS" "executable patched yasimavr interpreter (scripts/fetch_yasimavr.sh; YASIMAVR_VENV=)"
YASIMAVR_IMPORT='from yasimavr.device_library.descriptors import DeviceDescriptor; from yasimavr.device_library.builders._builders_arch_xt import XT_DeviceBuilder; from yasimavr.device_library.builders import dev_tiny_0series; from yasimavr.lib import core'
if [ -f "$YASIMAVR_PY_ABS" ] && [ -x "$YASIMAVR_PY_ABS" ] \
		&& ! "$YASIMAVR_PY_ABS" -c "$YASIMAVR_IMPORT" >/dev/null 2>&1; then
	MISSING+=("yasimavr target-module imports  (rebuild: scripts/fetch_yasimavr.sh)")
fi

# Staging (step 4) runs on the far side of the ~24-hour soak, so a destination
# that cannot be written there costs the whole run. OUTPUT_DIR itself must not
# exist (asserted above), so walk up to the nearest EXISTING ancestor and
# require that it be a writable directory NOW.
STAGE_ANCHOR="$OUTPUT_DIR"
if [ "$PREFLIGHT" -eq 1 ] && [ "$OUTPUT_EXISTS" -eq 1 ]; then
	# Test the capability to create a fresh leaf, not the conflicting leaf's own
	# type/mode. A real release still rejects the conflict above.
	STAGE_ANCHOR=$(dirname "$OUTPUT_DIR")
fi
while [ ! -e "$STAGE_ANCHOR" ]; do
	stage_up=$(dirname "$STAGE_ANCHOR")
	[ "$stage_up" = "$STAGE_ANCHOR" ] && break
	STAGE_ANCHOR="$stage_up"
done
if [ ! -d "$STAGE_ANCHOR" ]; then
	MISSING+=("$STAGE_ANCHOR  (staging path's nearest existing ancestor is not a directory)")
elif [ ! -w "$STAGE_ANCHOR" ] || [ ! -x "$STAGE_ANCHOR" ]; then
	MISSING+=("$STAGE_ANCHOR  (not writable/searchable; step 4 stages $OUTPUT_DIR under it)")
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
	log "Release preconditions NOT met (a release fails loud here, never mid-run):"
	for m in "${MISSING[@]}"; do log "  - $m"; done
	die "resolve the above (see TOOLCHAIN.adoc) and re-run."
fi

# These values are publication metadata, but computing them exercises the
# selected AWK. Do it only after its capability probe has passed.
PIC10F322_CLK_MHZ=$("$AWK" -v h="${PIC10F322_XTAL//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
XT_CLK_MHZ=$("$AWK" -v h="${XT_F_CPU//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
PIC10F320_CLK_MHZ=$("$AWK" -v h="${PIC10F320_XTAL//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
PIC12F675_CLK_MHZ=$("$AWK" -v h="${PIC12F675_XTAL//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
if [ "$PREFLIGHT" -eq 1 ]; then
	ok "all required release tools, headers, imports and staging-path capabilities are present."
else
	ok "working tree clean @ $GIT_SHORT; tag $VERSION free; all tools present."
fi

# The release is signed BY HAND at step 5 with the pinned release key -- roughly
# 24 hours after this point. An operator whose keyring lacks that secret key
# would not find out until the soak had already cost a day, so surface it now.
#
# WARN, never fail: this script signs nothing itself (all modifying git/signing
# operations are the human's), and keeping the release secret key on a separate
# or air-gapped machine is a legitimate -- arguably better -- workflow. A dry run
# emits no git commands at all, so it says nothing.
if [ "$DRY_RUN" -eq 0 ] \
		&& ! gpg --list-secret-keys "$RELEASE_SIGNING_FINGERPRINT" >/dev/null 2>&1; then
	warn "no SECRET key for the pinned release signer $RELEASE_SIGNING_FINGERPRINT in this keyring."
	warn "  Step 5 signs SHA256SUMS and the annotated tag with exactly that key."
	warn "  Fine if you sign on another machine; otherwise import it BEFORE the ~24 h soak."
fi

# ----------------------------------------------------------------------------
# Record toolchain versions (for the manifest) and warn on drift from the pins.
# ----------------------------------------------------------------------------
pkgver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "n/a"; }

# Record the SAME binaries the preconditions asserted and the build will run --
# not their default names -- so an overridden toolchain cannot be validated here
# while the manifest attests to a different one.
TC_AVR_GCC=$(release_tool_version_line "AVR GCC (CC=$AVR_CC)" "$AVR_CC") \
	|| die "could not record the AVR compiler provenance"
TC_AVR_BU=$(release_tool_version_line "AVR objcopy (OBJCOPY=$AVR_OBJCOPY)" "$AVR_OBJCOPY") \
	|| die "could not record the AVR binutils provenance"
TC_AVR_LIBC=$(pkgver avr-libc)
TC_HOST_CC=$(release_tool_version_line "host C compiler (HOSTCC=$HOST_CC)" "$HOST_CC") \
	|| die "could not record the host compiler provenance"
TC_XC8_322=$(release_tool_version_line "PIC10F322 XC8 (PIC_CC=$PIC_CC)" "$PIC_CC") \
	|| die "could not record the PIC10F322 compiler provenance"
TC_XC8_320=$(release_tool_version_line "PIC10F320 XC8 (PIC10F320_CC=$PIC10F320_CC)" "$PIC10F320_CC") \
	|| die "could not record the PIC10F320 compiler provenance"
TC_GPSIM=$(release_tool_version_line "gpsim (GPSIM=$GPSIM)" "$GPSIM") \
	|| die "could not record the gpsim provenance"
TC_SIMAVR=$(pkgver libsimavr-dev)
TC_CPPCHECK=$(release_tool_version_line "cppcheck (CPPCHECK=$CPPCHECK)" "$CPPCHECK") \
	|| die "could not record the cppcheck provenance"
TC_CBMC=$(release_tool_version_line "CBMC (CBMC=$CBMC)" "$CBMC") \
	|| die "could not record the CBMC provenance"
TC_CLANG=$(release_tool_version_line "Clang (CLANG=$CLANG)" "$CLANG") \
	|| die "could not record the Clang provenance"
TC_PY=$(release_tool_version_line "Python" python3) \
	|| die "could not record the Python provenance"
TC_PIC12F675_PY=$(release_tool_version_line \
	"PIC12F675 Python (PIC12F675_PYTHON=$PIC12F675_PYTHON)" \
	"$PIC12F675_PYTHON") \
	|| die "could not record the PIC12F675 Python provenance"

# These three tools define the released image bytes, so their versions are the
# release contract, not advisory. Reject drift here -- at preflight, before any
# build or soak -- rather than warning and relying on the CI repro-verify to fail
# a day later. Analyzer/simulator versions are recorded (below, into the MANIFEST)
# but deliberately NOT pinned; see TOOLCHAIN.adoc "What the release enforces".
#
# The comparison is EXACT. It used to be a shell substring pattern, which
# accepted any banner CONTAINING the pin -- avr-gcc 17.3.0 satisfied *7.3.0*
# and XC8 V3.100 satisfied *V3.10* -- so the enforcement TOOLCHAIN.adoc and the
# release workflow header promise was weaker than advertised for exactly the
# neighbouring versions a drifting host is most likely to have. See
# release_pinned_version_matches() for what counts as a version token.
#
# Each check reads the banner of the tool the preconditions actually selected
# ($AVR_CC / $PIC_CC / $PIC10F320_CC), not of a default name on PATH, so an
# overridden compiler is the one that gets pinned. PIC12F675 shares PIC_CC with
# the PIC10F322, so that one check covers both image families.
require_pinned_compiler() {
	local what=$1 selector=$2 tool=$3 banner=$4 pin=$5 display=$6
	release_pinned_version_matches "$banner" "$pin" && return 0
	die "$what is not the pinned $display.
      selected tool:     $tool (via $selector)
      observed banner:   $banner
      expected version:  exactly $display, compared as a whole token -- 1$pin, ${pin}0 and $pin.1 are all rejected
      corrective action: install $what $display, or point $selector at an installation that is exactly $display
The released images are byte-gated against this exact compiler; refusing to start a release with a drifted image-defining toolchain."
}

require_pinned_compiler "avr-gcc" CC "$AVR_CC" "$TC_AVR_GCC" 7.3.0 7.3.0
require_pinned_compiler "PIC10F322/PIC12F675 XC8" PIC_CC "$PIC_CC" "$TC_XC8_322" 3.10 V3.10
require_pinned_compiler "PIC10F320 XC8" PIC10F320_CC "$PIC10F320_CC" "$TC_XC8_320" 3.10 V3.10

if [ "$PREFLIGHT" -eq 1 ]; then
	ok "preflight passed: this host can start a release."
	exit 0
fi

# A real release is cut from main, where any branch-only working document
# (root-level v*-polish.md or pre-v*-fixes.md, and any other root-level document
# outside the durable set) must already be deleted and de-referenced. Enforce
# that here -- after the preflight capability probe, which legitimately runs
# against a live polish branch, and before any build -- so a release started
# from an un-merged polish branch fails fast instead of trusting the manual
# pre-merge checklist. Dry runs remain branch-safe rehearsals; every publishable
# mode -- production and express alike -- requires the checked-out main ref,
# because both stage into release/<version> and end at a signed tag.
case "$RELEASE_MODE" in
	production|express)
		release_require_main_branch "$REPO_ROOT" "$RELEASE_MODE" \
			|| die "refusing $RELEASE_MODE release outside the main branch (see the diagnostic above)."
		;;
esac
release_reject_branch_only_documents "$REPO_ROOT" \
	|| die "refusing to release: a branch-only working document is still present or referenced (see the diagnostic above)."

# ============================================================================
# 1. CLEAN BUILD -- every image
# ============================================================================
section "1. clean build (all variants x release-supported MCUs)"
make clean >/dev/null
make attiny13a attiny85 attiny45 >"$EVID/build-avr-classic.log" 2>&1 || { cat "$EVID/build-avr-classic.log" >&2; die "AVR build failed."; }
# ATtiny202: STRICT_TOOLS=1 so an absent ATtiny_DFP is a hard failure here rather
# than a clean skip that would leave build_avr_xt/ empty and be caught much later
# as three missing images. The build enforces both flash and static-RAM limits;
# the later attiny202-test qualification adds the shell frame gate.
make attiny202 STRICT_TOOLS=1 XT_DFP="$XT_DFP" \
	XT_STATIC_RAM_LIMIT="$RELEASE_XT_STATIC_RAM_LIMIT" \
	>"$EVID/build-avr-xt.log" 2>&1 \
	|| { cat "$EVID/build-avr-xt.log" >&2; die "ATtiny202 build failed."; }
make pic10f322 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" >"$EVID/build-pic10f322.log" 2>&1 || { cat "$EVID/build-pic10f322.log" >&2; die "PIC build failed."; }
# pic10f320-variants builds all three and, on any failure, removes the WHOLE image
# set rather than leaving a partial matrix behind for a later step to stage.
make pic10f320-variants PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	>"$EVID/build-pic10f320.log" 2>&1 \
	|| { cat "$EVID/build-pic10f320.log" >&2; die "PIC10F320 build failed."; }
# PIC12F675 shares PIC_CC/PIC_DFP with the 322. `make pic12f675` builds all three
# shipped HEXes plus the 1024-word flash and 48/64-byte Data-space gates and,
# like the 322, removes its whole product set on any failure rather than leaving
# a partial matrix behind. The
# DERIVED simcal images the soak needs are NOT built here; they are produced by
# the soak-binary dependency in section 3, from these exact shipped HEXes.
make pic12f675 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	PIC12F675_DATA_LIMIT="$RELEASE_PIC12F675_DATA_LIMIT" \
	>"$EVID/build-pic12f675.log" 2>&1 \
	|| { cat "$EVID/build-pic12f675.log" >&2; die "PIC12F675 build failed."; }

# Enumerate the expected image set and assert each exists.
IMAGES=()
AVR_IMAGES=()
AVR_ELFS=()
XT_IMAGES=()
XT_ELFS=()
PIC_IMAGES=()
PIC10F320_IMAGES=()
# PIC12F675 kept in its own arrays, out of PIC_IMAGES, for the same reason the
# ATtiny202 is kept out of AVR_IMAGES: PIC_IMAGES is bound to "the image the soak
# exercised", and the PIC12F675 soak exercises its DERIVED simcal image, not
# these shipped HEXes. PIC12F675_SIMCAL_IMAGES is populated in section 3 once the
# soak build has derived them.
PIC12F675_IMAGES=()
PIC12F675_SIMCAL_IMAGES=()
for v in $VARIANTS; do
	img="$(fw_image "$AVR_BUILD_DIR" "$ATTINY13A_MCU" "$v").hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); AVR_IMAGES+=("$img"); AVR_ELFS+=("$elf")
done
for v in $VARIANTS; do for n in $TINYX5; do
	img="$(fw_image "$AVR_BUILD_DIR" "attiny${n}" "$v").hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); AVR_IMAGES+=("$img"); AVR_ELFS+=("$elf")
done; done
# ATtiny202 is kept in its own arrays rather than folded into AVR_IMAGES: the
# classic lane's final step regenerates HEX from validated ELFs with
# `make attiny13a attiny85 attiny45`, which knows nothing about the AVR-XT build.
for v in $XT_VARIANTS; do
	img="$(fw_image "$XT_BUILD_DIR" "$XT_TAG" "$v").hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); XT_IMAGES+=("$img"); XT_ELFS+=("$elf")
done
for v in $VARIANTS; do
	img="$(fw_image "$PIC10F322_BUILD_DIR" "$PIC10F322_TAG" "$v").hex"
	IMAGES+=("$img"); PIC_IMAGES+=("$img")
done
for v in $PIC10F320_VARIANTS; do
	img="$(fw_image "$PIC10F320_BUILD_DIR" "$PIC10F320_TAG" "$v").hex"
	IMAGES+=("$img"); PIC_IMAGES+=("$img"); PIC10F320_IMAGES+=("$img")
done
# PIC12F675 shipped HEXes join the master IMAGES set (so they are enumerated,
# cross-checked against RELEASE_IMAGES, staged and checksummed like everything
# else) but NOT PIC_IMAGES (see the array declaration above).
for v in $VARIANTS; do
	img="$(fw_image "$PIC12F675_BUILD_DIR" "$PIC12F675_TAG" "$v").hex"
	IMAGES+=("$img"); PIC12F675_IMAGES+=("$img")
done
for img in "${IMAGES[@]}"; do [ -f "$img" ] || die "expected image not produced: $img"; done

# Cross-check the enumeration against the canonical set BEFORE any validation
# runs, so a mismatch costs seconds rather than a 24-hour soak. This is the
# check that catches a forgotten build step: the enumeration above is derived
# from the same variant matrices as the build commands, so it would shrink in
# lock-step with an omission and never notice. RELEASE_IMAGES would not.
enumerated=$(for img in "${IMAGES[@]}"; do basename "$img"; done | LC_ALL=C sort)
canonical=$(printf '%s\n' $RELEASE_IMAGES | LC_ALL=C sort)
if [ "$enumerated" != "$canonical" ]; then
	log "release set mismatch (left: built by this script, right: Makefile RELEASE_IMAGES):"
	diff -u <(printf '%s\n' "$enumerated") <(printf '%s\n' "$canonical") >&2 || true
	die "the images this release builds do not match the canonical release product set."
fi
ok "built ${#IMAGES[@]} images; set matches the canonical RELEASE_IMAGES exactly."

# Structural Intel-HEX validation of every PIC10F320 image. The PIC10F322 lane
# gets this inside `make pic10f322`, and the 320's `make pic10f320` validates each image
# as it is produced; repeating it here covers the window between build and
# staging, and costs nothing.
for img in "${PIC10F320_IMAGES[@]}"; do
	scripts/validate-ihex.sh "$img" >/dev/null \
		|| die "PIC10F320 image failed Intel-HEX validation: $img"
done
ok "all ${#PIC10F320_IMAGES[@]} PIC10F320 images are structurally valid Intel HEX."
for img in "${PIC12F675_IMAGES[@]}"; do
	scripts/validate-ihex.sh "$img" >/dev/null \
		|| die "PIC12F675 image failed Intel-HEX validation: $img"
done
ok "all ${#PIC12F675_IMAGES[@]} PIC12F675 images are structurally valid Intel HEX."

hash_avr_elf_set() {
	local elf
	for elf in "$@"; do
		[ -f "$elf" ] && [ ! -L "$elf" ] && [ -s "$elf" ] \
			|| die "validated classic AVR ELF missing, empty, or not regular: $elf"
	done
	sha256sum -- "$@"
}

hash_pic_image_set() {
	local image result hash
	for image in "$@"; do
		[ -f "$image" ] && [ ! -L "$image" ] && [ -s "$image" ] \
			|| die "validated PIC image missing, empty, or not regular: $image"
		result=$(sha256sum -- "$image") || return 1
		hash=${result%% *}
		printf '%s  %s\n' "$hash" "${image##*/}"
	done
}

# The AVR-XT equivalent, over HEX *and* ELF. Both matter: the staged artifact is
# the HEX, but every yasimavr gate and the whole soak phase drive the ELF, so
# evidence is only bound to the shipped image while the pair stays in step.
# `make attiny202` rebuilds unconditionally (its recipe removes its outputs
# first), so this is also the check that the build is actually reproducible
# across the several times validation re-enters it.
hash_xt_image_set() {
	local f result hash
	for f in "$@"; do
		[ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] \
			|| die "validated ATtiny202 artifact missing, empty, or not regular: $f"
		result=$(sha256sum -- "$f") || return 1
		hash=${result%% *}
		printf '%s  %s\n' "$hash" "${f##*/}"
	done
}

# ============================================================================
# 2. FULL PRE-HARDWARE GATES
# ============================================================================
section "2. validation: test-long + ATtiny202 and both PIC chips' pre-hardware/target gates"
# PIC12F675_FLASH_IMAGES=build: the flashing-helper gate inside test-long must
# exercise the images section 1 just rebuilt from this release's source, not
# fall back to the previous release's HEXes. The fallback exists so `make test`
# runs on a host with no XC8; a release has no such excuse.
log "running make test-long (exhaustive AVR suite + mutation)..."
make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0 PIC12F675_FLASH_IMAGES=build \
	CC="$AVR_CC" OBJCOPY="$AVR_OBJCOPY" SIZE="$AVR_SIZE" \
	OBJDUMP="$AVR_OBJDUMP" READELF="$READELF" IHEX_VALIDATOR="$IHEX_VALIDATOR" \
	AWK="$AWK" HOSTCC="$HOST_CC" PIC10F320_HOST_CC="$PIC10F320_HOST_CC" \
	CLANG="$CLANG" ANALYZE_CMD="$ANALYZE_CMD" CPPCHECK="$CPPCHECK" \
	CBMC="$CBMC" GCOV="$GCOV" GPSIM="$GPSIM" SIMAVR_INC="$SIMAVR_INC" \
	PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	PIC_XC8_INCLUDE="$PIC_XC8_INCLUDE" PIC10F322_DFP_INCLUDE="$PIC10F322_DFP_INCLUDE" \
	PIC10F322_DEVICE_INI="$PIC10F322_DEVICE_INI" \
	PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	PIC10F320_XC8_INCLUDE="$PIC10F320_XC8_INCLUDE" \
	PIC10F320_DFP_INCLUDE="$PIC10F320_DFP_INCLUDE" \
	PIC10F320_DEVICE_INI="$PIC10F320_DEVICE_INI" \
	PIC_SOAK_CXX="$PIC_SOAK_CXX" PIC10F320_SOAK_CXX="$PIC10F320_SOAK_CXX" \
	PIC_SOAK_GPSIM_INC="$PIC_SOAK_GPSIM_INC" \
	PIC10F320_SOAK_GPSIM_INC="$PIC10F320_SOAK_GPSIM_INC" \
	XT_DFP="$XT_DFP" YASIMAVR_VENV="$YASIMAVR_VENV" \
	XT_STATIC_RAM_LIMIT="$RELEASE_XT_STATIC_RAM_LIMIT" \
	PIC12F675_DATA_LIMIT="$RELEASE_PIC12F675_DATA_LIMIT" \
	>"$EVID/test-long.log" 2>&1 \
	|| { tail -40 "$EVID/test-long.log" >&2; die "make test-long FAILED."; }
ok "test-long passed."
validated_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")

# ATtiny202 pre-hardware gates: fuses, smoke, build + 2 KB budget, cppcheck +
# MISRA, and the coil-pulse width oracle read back out of the built image.
log "running make attiny202-test (fuses + build/budget + analysis + delay oracle)..."
make attiny202-test STRICT_TOOLS=1 XT_DFP="$XT_DFP" \
	XT_STATIC_RAM_LIMIT="$RELEASE_XT_STATIC_RAM_LIMIT" \
	XT_STACK_MAX_FRAME="$RELEASE_XT_STACK_MAX_FRAME" \
	>"$EVID/attiny202-test.log" 2>&1 \
	|| { tail -40 "$EVID/attiny202-test.log" >&2; die "make attiny202-test FAILED."; }
ok "attiny202-test passed."

# Fail-closed AVR-XT target aggregate (yasimavr), the counterpart of the two PIC
# target aggregates below: per variant, functional + modeled PA2/PA3 output
# trace, critical-SFR/state fault injection, and firmware/model ctx_ lock-step.
# STRICT_TOOLS=1 converts each driver's clean skip into a hard failure.
log "running make attiny202-test-target (sim + fault + lock-step on the real image)..."
make attiny202-test-target STRICT_TOOLS=1 XT_DFP="$XT_DFP" \
	YASIMAVR_VENV="$YASIMAVR_VENV" \
	XT_STATIC_RAM_LIMIT="$RELEASE_XT_STATIC_RAM_LIMIT" \
	>"$EVID/attiny202-test-target.log" 2>&1 \
	|| { tail -60 "$EVID/attiny202-test-target.log" >&2; die "make attiny202-test-target FAILED."; }
ok "attiny202-test-target passed."
validated_xt_image_hashes=$(hash_xt_image_set "${XT_IMAGES[@]}")
validated_xt_elf_hashes=$(hash_xt_image_set "${XT_ELFS[@]}")

log "running make pic10f322-test (PIC CONFIG word + analyze + gpsim)..."
make pic10f322-test STRICT_TOOLS=1 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" >"$EVID/pic10f322-test.log" 2>&1 || { tail -40 "$EVID/pic10f322-test.log" >&2; die "make pic10f322-test FAILED."; }
ok "pic10f322-test passed."

# Fail-closed PIC target aggregate (libgpsim): per variant, require target fault
# recovery, firmware/model ctx_ lock-step, and GPIO transition/pulse timing PASS
# sentinels. This target converts the standalone skip-clean libgpsim drivers into
# a release gate: any missing tool, missing ctx_ symbol, skipped subtarget, or
# partial run is a hard failure.
log "running make pic10f322-test-target-variants (fault + lock-step + target I/O on the real HEX)..."
make pic10f322-test-target-variants STRICT_TOOLS=1 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	>"$EVID/pic10f322-test-target-variants.log" 2>&1 \
	|| { tail -60 "$EVID/pic10f322-test-target-variants.log" >&2; die "make pic10f322-test-target-variants FAILED."; }
ok "pic10f322-test-target-variants passed."

log "running make pic10f320-test (PIC10F320 host lanes + hashes + CONFIG + stack + analysis + gpsim, all variants)..."
make pic10f320-test STRICT_TOOLS=1 PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	>"$EVID/pic10f320-test.log" 2>&1 \
	|| { tail -60 "$EVID/pic10f320-test.log" >&2; die "make pic10f320-test FAILED."; }
ok "pic10f320-test passed."

log "running make pic10f320-test-target-variants (fault + lock-step + target I/O on the real HEX)..."
make pic10f320-test-target-variants STRICT_TOOLS=1 \
	PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	>"$EVID/pic10f320-test-target-variants.log" 2>&1 \
	|| { tail -60 "$EVID/pic10f320-test-target-variants.log" >&2; die "make pic10f320-test-target-variants FAILED."; }
ok "pic10f320-test-target-variants passed."
validated_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")

# PIC12F675's pre-hardware and target aggregates must run in ONE Make graph.
# Their shared phony prerequisite then qualifies one shipping/simulator/sidecar
# matrix exactly once, and every consumer names that same complete identity. A
# second Make process would silently replace the retained matrix and make the two
# logs evidence about different bytes.
PIC12F675_QUALIFICATION_LOG="$EVID/pic12f675-qualification.log"
PIC12F675_QUALIFIED_MATRIX="$EVID/pic12f675-qualified-matrix.json"
log "running one PIC12F675 qualification graph (pre-hardware + all target variants)..."
make pic12f675-test pic12f675-test-target-variants \
	STRICT_TOOLS=1 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	PIC12F675_DATA_LIMIT="$RELEASE_PIC12F675_DATA_LIMIT" \
	>"$PIC12F675_QUALIFICATION_LOG" 2>&1 \
	|| { tail -60 "$PIC12F675_QUALIFICATION_LOG" >&2; die "combined PIC12F675 qualification FAILED."; }
qualified_pic12f675_matrix_record=$(python3 "$PIC12F675_MATRIX_EVIDENCE" verify \
	--build-dir "$PIC12F675_BUILD_DIR" --fw-base "$FW_BASE" \
	--tag "$PIC12F675_TAG") \
	|| die "could not verify the PIC12F675 matrix after its combined qualification"
cp -p -- "$PIC12F675_MATRIX_MANIFEST" "$PIC12F675_QUALIFIED_MATRIX" \
	|| die "could not retain the qualified PIC12F675 matrix manifest"
retained_pic12f675_matrix_record=$(python3 "$PIC12F675_MATRIX_EVIDENCE" verify-file \
	--manifest "$PIC12F675_QUALIFIED_MATRIX" --fw-base "$FW_BASE" \
	--tag "$PIC12F675_TAG") \
	|| die "retained PIC12F675 matrix manifest is invalid"
[ "$retained_pic12f675_matrix_record" = "$qualified_pic12f675_matrix_record" ] \
	|| die "retained PIC12F675 matrix identity differs from the qualified build"
pic12f675_matrix_sha256=$(sha256sum -- "$PIC12F675_QUALIFIED_MATRIX") \
	|| die "could not hash the retained PIC12F675 matrix manifest"
pic12f675_matrix_sha256=${pic12f675_matrix_sha256%% *}

require_pic12f675_matrix_line() {
	local expected=$1 count
	count=$(grep -cFx -- "$expected" "$PIC12F675_QUALIFICATION_LOG" || true)
	[ "$count" -eq 1 ] \
		|| die "combined PIC12F675 qualification did not emit one exact matrix-bound PASS: $expected"
}
require_pic12f675_matrix_line \
	"=== PIC12F675 retained matrix qualified: $qualified_pic12f675_matrix_record ==="
require_pic12f675_matrix_line \
	"=== all PIC12F675 pre-hardware checks complete: $qualified_pic12f675_matrix_record ==="
for v in $VARIANTS; do
	require_pic12f675_matrix_line \
		"=== PIC12F675 target fault/lock-step/I-O PASS (variant $v): $qualified_pic12f675_matrix_record ==="
done
require_pic12f675_matrix_line \
	"=== PIC12F675 target fault/lock-step/I-O validated for all variants: $qualified_pic12f675_matrix_record ==="
matrix_line_count=$(grep -c 'PIC12F675_MATRIX_SHA256' \
	"$PIC12F675_QUALIFICATION_LOG" || true)
[ "$matrix_line_count" -eq 6 ] \
	|| die "combined PIC12F675 qualification emitted unexpected or duplicate matrix records"
ok "both PIC12F675 aggregates passed against one retained matrix."
validated_pic12f675_image_hashes=$(hash_pic_image_set "${PIC12F675_IMAGES[@]}")

# Strict resource evidence, measured HERE for the same reason the rename/change
# evidence above is: this gate reads only the images section 1 built and the
# logs section 2 just wrote -- nothing the soak produces, and nothing the soak
# may change (every one of those artifacts is pinned by hash across the soak
# below). A documented figure that drifted from the built image is therefore a
# failure this run can report in seconds instead of after a 24-hour wait.
#
# The report is written OUTSIDE $EVID on purpose. Staging copies every
# $EVID/*.log into the release, where the retained set must equal
# RELEASE_EVIDENCE_FILES exactly, so a second resource log there would fail
# qualification. The authoritative record is the one measured again after the
# soak, over the final image paths staging consumes; this one only fails fast.
log "checking final-candidate resource evidence (pre-soak fail-fast)..."
python3 "$REPO_ROOT/test/test_resource_tables.py" --root "$REPO_ROOT" \
	--require-all-images --evidence-dir "$EVID" --source-commit "$GIT_SHA" \
	>"$WORK/resource-tables-presoak.log" 2>&1 \
	|| { cat "$WORK/resource-tables-presoak.log" >&2; \
		die "resource evidence FAILED before the soak. No soak started."; }
ok "resource evidence covers all images and this run's measurements (rechecked after the soak)."

# ============================================================================
# 3. PARALLEL SOAK -- every release combo, full duration
# ============================================================================
section "3. soak (all release combos, parallel, ${SOAK_DURATION_MS} ms each)"

# Build metadata for every soak combo: a binary, the cwd to run it from, a log.
declare -a SOAK_NAMES=()
declare -A SOAK_BIN SOAK_CWD SOAK_LOG SOAK_RC

log "compiling soak binaries..."
for v in $VARIANTS; do for p in $TINYX5_PARTS; do
	# The binary path is READ from the Makefile, not composed here. Unlike the
	# image basenames above -- restated on purpose so they can be cross-checked
	# against RELEASE_IMAGES -- this path is cross-checked against nothing, and
	# a copy of it here severed silently once already: v0.9.8 renamed the
	# release's soak COMBINATIONS, updated this line to the new _attiny<n>
	# spelling, and left AVR_SOAK_BIN saying _t<n>. `make` was then asked for a
	# target that did not exist, which fails the release an hour in, at step 3.
	name="${p}_${v}"
	# --no-print-directory for the same reason mkv carries it: -s alone loses to
	# an inherited -w, and a banner here would name a soak binary that cannot
	# exist.
	bin=$(make -s --no-print-directory print-AVR_SOAK_BIN \
		AVR_SOAK_VARIANT="$v" AVR_SOAK_CHIP="$p") \
		|| die "cannot read AVR_SOAK_BIN for $name from the Makefile"
	[ -n "$bin" ] || die "AVR_SOAK_BIN expands empty for $name"
	elf="$(fw_image "$AVR_BUILD_DIR" "$p" "$v").elf"
	make --old-file="$elf" "$bin" AVR_REBUILD_PREREQ= \
		AVR_SOAK_VARIANT="$v" AVR_SOAK_CHIP="$p" AVR_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		AVR_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		AVR_SOAK_COMBINATION_NAME="$name" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build AVR soak $name"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$REPO_ROOT/$bin"
	SOAK_CWD[$name]="$REPO_ROOT"   # relative FW_PATH; the binary writes no files
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done; done
# ATtiny202: three more combos, one per output stage, at the same full duration
# as every other release combo. The driver is a Python script rather than a
# compiled binary, so each combo gets a tiny generated wrapper -- the soak
# launcher below execs one argument-less program per combination, and threading
# per-combo argv/env through it would complicate the one piece of this phase that
# must stay obviously correct. The wrapper pins the combination name that the
# driver binds into its SOAK_RESULT record, which validate_soak_result() then
# matches exactly, so a wrapper pointing at the wrong image cannot pass.
XT_FUSE_ENV_ARGS=()
for f in $XT_FUSE_NAMES; do
	XT_FUSE_ENV_ARGS+=("ATTINY202_FUSE_$(printf '%s' "$f" | tr '[:lower:]' '[:upper:]')=${XT_FUSE[$f]}")
done
for v in $XT_VARIANTS; do
	name="attiny202_${v}"; bin="$SOAKDIR/soak_attiny202_${v}.sh"
	elf="$REPO_ROOT/$(fw_image "$XT_BUILD_DIR" "$XT_TAG" "$v").elf"
	[ -f "$elf" ] || die "ATtiny202 soak ELF missing: $elf"
	{
		printf '#!/bin/sh\n'
		printf '# generated by make-release.sh -- ATtiny202 release soak combo %s\n' "$name"
		printf 'set -e\n'
		printf 'cd %q\n' "$REPO_ROOT"
		printf 'exec env PYTHONPATH=test/avr \\\n'
		for e in "${XT_FUSE_ENV_ARGS[@]}"; do printf '  %q \\\n' "$e"; done
		printf '  ATTINY202_SOAK_DURATION_MS=%q \\\n' "$SOAK_DURATION_MS"
		printf '  ATTINY202_SOAK_LIVENESS_INTERVAL_MS=%q \\\n' "$SOAK_LIVENESS_INTERVAL_MS"
		printf '  ATTINY202_SOAK_PROGRESS_INTERVAL_MS=%q \\\n' "$SOAK_LIVENESS_INTERVAL_MS"
		printf '  ATTINY202_SOAK_COMBINATION_NAME=%q \\\n' "$name"
		printf '  %q %q %q\n' "$YASIMAVR_PY_ABS" \
			"$REPO_ROOT/test/avr/test_soak_attiny202.py" "$elf"
	} > "$bin" || die "could not write ATtiny202 soak wrapper $bin"
	chmod +x "$bin" || die "could not make $bin executable"
	printf 'generated ATtiny202 soak wrapper: %s -> %s\n' "$name" "$elf" \
		>>"$EVID/soak-build.log"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$REPO_ROOT"   # the wrapper cd's itself; nothing is written here
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done
for v in $VARIANTS; do
	name="pic10f322_${v}"; bin="$SOAKDIR/test_soak_pic10f322_${v}"
	make "$bin" PIC10F322_SOAK_BIN="$bin" PIC10F322_SOAK_VARIANT="$v" PIC10F322_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		PIC10F322_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		PIC10F322_SOAK_COMBINATION_NAME="$name" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build PIC soak $name"
	rundir="$SOAKDIR/run-$name"; mkdir -p "$rundir"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done
# Three more combos, one per PIC10F320 output stage -- the same full duration as
# every other release combo, not a shortened smoke. Each drives its own real HEX
# in libgpsim. PIC10F320_SOAK_VARIANT selects the image; the driver itself is the
# shared parent one (§4: the parent copy is ahead, carrying SOAK_LIVENESS_DUE).
for v in $PIC10F320_VARIANTS; do
	name="pic10f320_${v}"; bin="$SOAKDIR/test_soak_pic10f320_${v}"
	make "$bin" PIC10F320_SOAK_BIN="$bin" PIC10F320_SOAK_VARIANT="$v" \
		PIC10F320_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		PIC10F320_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		PIC10F320_SOAK_COMBINATION_NAME="$name" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build PIC10F320 soak $name"
	rundir="$SOAKDIR/run-$name"; mkdir -p "$rundir"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done
# Three more combos, one per PIC12F675 output stage. UNIQUE to this part: the soak
# drives a DERIVED simcal image, not the shipped HEX. The direct binary target's
# normal prerequisite rebuilds pic12f675-simcal, so release staging marks that
# producer old: the harness must compile from the exact matrix already qualified
# above, never replace it with a later build. Reverify all twelve artifacts after
# every harness compile. Record each derived image so it is also pinned unchanged
# across the soak, exactly as the ATtiny202 ELF is.
for v in $VARIANTS; do
	name="pic12f675_${v}"; bin="$SOAKDIR/test_soak_pic12f675_${v}"
	make --old-file=_pic12f675-build-soak "$bin" \
		PIC12F675_SOAK_BIN="$bin" PIC12F675_SOAK_VARIANT="$v" \
		PIC12F675_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		PIC12F675_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		PIC12F675_SOAK_COMBINATION_NAME="$name" \
		PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build PIC12F675 soak $name"
	current_pic12f675_matrix_record=$(python3 "$PIC12F675_MATRIX_EVIDENCE" verify \
		--build-dir "$PIC12F675_BUILD_DIR" --fw-base "$FW_BASE" \
		--tag "$PIC12F675_TAG") \
		|| die "PIC12F675 matrix changed while compiling soak $name"
	[ "$current_pic12f675_matrix_record" = "$qualified_pic12f675_matrix_record" ] \
		|| die "PIC12F675 soak $name was compiled from a different qualified matrix"
	PIC12F675_SIMCAL_IMAGES+=("$(fw_image "$PIC12F675_SIMCAL_DIR" "$PIC12F675_TAG" "$v")_simcal.hex")
	rundir="$SOAKDIR/run-$name"; mkdir -p "$rundir"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done
# Baseline the derived simcal images now that they exist. The shipped HEXes were
# already hashed after their gate; both sets are re-checked unchanged across the
# soak below, and the gate proved simcal = shipped-HEX with only word 0x3FF
# changed -- so a stable pair here means the soak exercised the shipped firmware.
validated_pic12f675_simcal_hashes=$(hash_pic_image_set "${PIC12F675_SIMCAL_IMAGES[@]}")

# Soak harness compilation must not replace the ELFs that test-long exercised.
current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a classic AVR ELF changed while compiling its soak harness"
current_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")
[ "$current_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a PIC image changed while compiling its soak harness"
current_pic12f675_image_hashes=$(hash_pic_image_set "${PIC12F675_IMAGES[@]}")
[ "$current_pic12f675_image_hashes" = "$validated_pic12f675_image_hashes" ] \
	|| die "a PIC12F675 shipped image changed while compiling its soak harness"
current_xt_image_hashes=$(hash_xt_image_set "${XT_IMAGES[@]}")
current_xt_elf_hashes=$(hash_xt_image_set "${XT_ELFS[@]}")
{ [ "$current_xt_image_hashes" = "$validated_xt_image_hashes" ] \
	&& [ "$current_xt_elf_hashes" = "$validated_xt_elf_hashes" ]; } \
	|| die "an ATtiny202 image or ELF changed while preparing its soak wrappers"

NCOMBOS=${#SOAK_NAMES[@]}
actual_soaks=$(printf '%s\n' "${SOAK_NAMES[@]}" | LC_ALL=C sort)
canonical_soaks=$(printf '%s\n' $RELEASE_SOAK_NAMES | LC_ALL=C sort)
if [ "$actual_soaks" != "$canonical_soaks" ]; then
	diff -u <(printf '%s\n' "$canonical_soaks") <(printf '%s\n' "$actual_soaks") >&2 || true
	die "release soak combinations do not match canonical RELEASE_SOAK_NAMES"
fi
JOBS=$(release_jobs_cap "$JOBS" "$NCOMBOS") \
	|| die "could not resolve the release soak concurrency limit"
hours=$("$AWK" -v ms="$SOAK_DURATION_MS" 'BEGIN{printf "%.1f", ms/3600000}')
ncpu=$(nproc 2>/dev/null || echo "?")
log "launching $NCOMBOS soak combos, up to $JOBS at once (~${hours} h each; this box has $ncpu logical CPUs)."
[ "$JOBS" -lt "$NCOMBOS" ] && warn "more combos ($NCOMBOS) than the --jobs cap ($JOBS): total time scales up."

START_EPOCH=$(date +%s)
declare -A SOAK_PID
for name in "${SOAK_NAMES[@]}"; do
	# Throttle to JOBS concurrent runs.
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 5; done
	# Defer a signal only across this launch-and-track critical section. The
	# pending status is replayed immediately after the PID/process-group ID is in
	# SOAK_PIDS, so no child can escape cleanup in the `$!` assignment gap.
	TRACKING_WORKER=1
	( cd "${SOAK_CWD[$name]}" && exec setsid "${SOAK_BIN[$name]}" ) \
		>"${SOAK_LOG[$name]}" 2>&1 &
	SOAK_PID[$name]=$!
	SOAK_PIDS+=("${SOAK_PID[$name]}")
	TRACKING_WORKER=0
	if [ "$PENDING_SIGNAL_STATUS" -ne 0 ]; then
		pending=$PENDING_SIGNAL_STATUS
		PENDING_SIGNAL_STATUS=0
		exit "$pending"
	fi
	log "  started $name (pid ${SOAK_PID[$name]})"
done

forget_soak_pid() {
	local target=$1 index
	for index in "${!SOAK_PIDS[@]}"; do
		[ "${SOAK_PIDS[$index]}" != "$target" ] || unset "SOAK_PIDS[$index]"
	done
}

# One exact terminal record is the machine contract shared by both harnesses.
# It binds the log to its combination and compile-time timing, requires the
# expected nonzero liveness-check count, and reports every failure counter.
expected_soak_checks=$((SOAK_DURATION_MS / SOAK_LIVENESS_INTERVAL_MS))
validate_soak_result() {
	local name=$1 log=$2 expected
	local -a records pass_lines
	mapfile -t records < <(grep '^SOAK_RESULT ' "$log" || true)
	[ "${#records[@]}" -eq 1 ] || return 1
	expected="SOAK_RESULT format=1 status=pass combination=$name duration_ms=$SOAK_DURATION_MS liveness_interval_ms=$SOAK_LIVENESS_INTERVAL_MS checks=$expected_soak_checks failures=0 watchdog_failures=0 liveness_failures=0"
	[ "${records[0]}" = "$expected" ] || return 1
	mapfile -t pass_lines < <(grep "^SOAK PASS: $SOAK_DURATION_MS ms " "$log" || true)
	[ "${#pass_lines[@]}" -eq 1 ] || return 1
	! grep -q '^SOAK FAIL' "$log"
}

# Wait for all and collect verdicts. Exit status and the complete machine record
# must agree; either one alone is insufficient evidence.
SOAK_FAILS=0
for name in "${SOAK_NAMES[@]}"; do
	if wait "${SOAK_PID[$name]}"; then SOAK_RC[$name]=0; else SOAK_RC[$name]=$?; fi
	forget_soak_pid "${SOAK_PID[$name]}"
	unset "SOAK_PID[$name]"
	if [ "${SOAK_RC[$name]}" -eq 0 ] \
			&& validate_soak_result "$name" "${SOAK_LOG[$name]}"; then
		ok "soak $name: PASS"
	else
		warn "soak $name: FAIL (exit ${SOAK_RC[$name]})  -- see ${SOAK_LOG[$name]}"
		SOAK_FAILS=$((SOAK_FAILS+1))
	fi
done
SOAK_PIDS=()
SOAK_WALL=$(( $(date +%s) - START_EPOCH ))

if [ "$SOAK_FAILS" -ne 0 ]; then
	die "$SOAK_FAILS soak combo(s) FAILED. No release staged. Logs in $WORK (preserved)."
fi
ok "all $NCOMBOS soak combos passed (wall-clock ${SOAK_WALL}s)."

current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a classic AVR ELF changed after its final validation began"
current_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")
[ "$current_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a PIC image changed while its soak was running"
current_pic12f675_image_hashes=$(hash_pic_image_set "${PIC12F675_IMAGES[@]}")
[ "$current_pic12f675_image_hashes" = "$validated_pic12f675_image_hashes" ] \
	|| die "a PIC12F675 shipped image changed while its soak was running"
current_pic12f675_simcal_hashes=$(hash_pic_image_set "${PIC12F675_SIMCAL_IMAGES[@]}")
[ "$current_pic12f675_simcal_hashes" = "$validated_pic12f675_simcal_hashes" ] \
	|| die "a PIC12F675 simcal image changed while its soak was running"
current_pic12f675_matrix_record=$(python3 "$PIC12F675_MATRIX_EVIDENCE" verify \
	--build-dir "$PIC12F675_BUILD_DIR" --fw-base "$FW_BASE" \
	--tag "$PIC12F675_TAG") \
	|| die "the qualified PIC12F675 matrix changed while its soak was running"
[ "$current_pic12f675_matrix_record" = "$qualified_pic12f675_matrix_record" ] \
	|| die "the PIC12F675 soak completed against a different qualified matrix"
current_xt_image_hashes=$(hash_xt_image_set "${XT_IMAGES[@]}")
current_xt_elf_hashes=$(hash_xt_image_set "${XT_ELFS[@]}")
{ [ "$current_xt_image_hashes" = "$validated_xt_image_hashes" ] \
	&& [ "$current_xt_elf_hashes" = "$validated_xt_elf_hashes" ]; } \
	|| die "an ATtiny202 image or ELF changed while its soak was running"

# Validation and soak rebuild classic ELFs, invalidating their paired HEX files.
# Re-materialize HEX from those exact, just-tested ELFs without compiling again.
log "regenerating classic AVR HEX from the validated ELFs..."
rm -f -- "${AVR_IMAGES[@]}" \
	|| die "could not remove stale classic AVR HEX before final regeneration"
old_file_args=()
for elf in "${AVR_ELFS[@]}"; do old_file_args+=("--old-file=$elf"); done
make "${old_file_args[@]}" attiny13a attiny85 attiny45 AVR_REBUILD_PREREQ= \
	>"$EVID/final-image-build.log" 2>&1 \
	|| { tail -60 "$EVID/final-image-build.log" >&2; die "final classic HEX regeneration FAILED."; }
current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a validated classic AVR ELF changed during final HEX regeneration"
final_avr_image_hashes=$(release_hash_classic_avr_images "${AVR_IMAGES[@]}") \
	|| die "could not hash the final classic AVR HEX regenerated from validated ELFs"
for img in "${IMAGES[@]}"; do
	[ -f "$img" ] && [ ! -L "$img" ] && [ -s "$img" ] \
		|| die "validated release image missing, empty, or not regular after final regeneration: $img"
done
current_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")
[ "$current_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a validated PIC image changed before staging"
current_pic12f675_image_hashes=$(hash_pic_image_set "${PIC12F675_IMAGES[@]}")
[ "$current_pic12f675_image_hashes" = "$validated_pic12f675_image_hashes" ] \
	|| die "a validated PIC12F675 image changed before staging"
current_pic12f675_matrix_record=$(python3 "$PIC12F675_MATRIX_EVIDENCE" verify \
	--build-dir "$PIC12F675_BUILD_DIR" --fw-base "$FW_BASE" \
	--tag "$PIC12F675_TAG") \
	|| die "the qualified PIC12F675 matrix changed before staging"
[ "$current_pic12f675_matrix_record" = "$qualified_pic12f675_matrix_record" ] \
	|| die "the final PIC12F675 matrix differs from the retained qualification"
ok "all validated release images are present and nonempty."

# Convert the final image set and this run's full resource-bearing logs into one
# strict, source-bound record before test-long.log is summarized. Ordinary CI
# may compare zero images; this release path must measure all 21, all 12 AVR
# static-data records, and every retained stack/Data-space observation.
#
# The same gate already passed before the soak, against the same logs and the
# same build directories. This second measurement is the one that is retained,
# hashed into QUALIFICATION and staged: it reads the final image paths -- the
# classic AVR HEX regenerated just above included -- so a byte that changed
# after the early check fails here rather than leaving evidence about different
# files. Reaching this line and failing means something moved during the soak.
python3 "$REPO_ROOT/test/test_resource_tables.py" --root "$REPO_ROOT" \
	--require-all-images --evidence-dir "$EVID" --source-commit "$GIT_SHA" \
	>"$EVID/resource-tables.log" 2>&1 \
	|| { cat "$EVID/resource-tables.log" >&2; die "final resource evidence FAILED."; }
resource_tables_sha256=$(sha256sum -- "$EVID/resource-tables.log") \
	|| die "could not hash final resource evidence"
resource_tables_sha256=${resource_tables_sha256%% *}
ok "final resource evidence covers all images and retained RAM/stack measurements."

# Builds and parallel soaks can run for 24 hours. The Make lock protects shared
# artifacts from other Make invocations, but intentionally cannot prevent a
# human or editor from changing source or moving HEAD. Recheck immediately
# before creating the release directory so the recorded commit still identifies
# the validated source. Dirty rehearsals retain their explicit warning policy.
if ! release_source_is_unchanged "$GIT_SHA" "$DRY_RUN"; then
	die "source provenance changed after validation. No release staged."
fi
ok "source provenance still matches $GIT_SHORT immediately before staging."
# An explicit dry-run output may live under a path controlled outside this
# worktree. Resolve it again after the long-running gates so replacing a parent
# with a symlink cannot redirect rehearsal artifacts into release/<version>.
release_output_path_is_safe "$REPO_ROOT" "$OUTPUT_DIR" "$RELEASE_MODE" "$VERSION"

# ============================================================================
# 4. STAGE THE RELEASE
# ============================================================================
section "4. stage $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/evidence"
release_stage_classic_avr_images "$OUTPUT_DIR" "$final_avr_image_hashes" \
	"${AVR_IMAGES[@]}" \
	|| die "a staged classic AVR image differs from the final HEX regenerated from its validated ELF"
for img in "${XT_IMAGES[@]}" "${PIC_IMAGES[@]}" "${PIC12F675_IMAGES[@]}"; do
	cp -p -- "$img" "$OUTPUT_DIR/"
done
STAGED_PIC_IMAGES=()
for img in "${PIC_IMAGES[@]}"; do STAGED_PIC_IMAGES+=("$OUTPUT_DIR/$(basename "$img")"); done
staged_pic_image_hashes=$(hash_pic_image_set "${STAGED_PIC_IMAGES[@]}")
[ "$staged_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a staged PIC image differs from the image exercised by the soak"
# PIC12F675 is bound separately, like the ATtiny202: its soak exercised the
# derived simcal image, so the shipped HEX is bound to what its GATES validated
# (section 2, including pic12f675-test-calibration, which pins simcal to this
# exact HEX modulo word 0x3FF), and the simcal image is bound unchanged across
# the soak above. The two chains meet at the calibration gate.
STAGED_PIC12F675_IMAGES=()
for img in "${PIC12F675_IMAGES[@]}"; do STAGED_PIC12F675_IMAGES+=("$OUTPUT_DIR/$(basename "$img")"); done
staged_pic12f675_image_hashes=$(hash_pic_image_set "${STAGED_PIC12F675_IMAGES[@]}")
[ "$staged_pic12f675_image_hashes" = "$validated_pic12f675_image_hashes" ] \
	|| die "a staged PIC12F675 image differs from the one its gates validated and its soak's calibration preimage"
STAGED_XT_IMAGES=()
for img in "${XT_IMAGES[@]}"; do STAGED_XT_IMAGES+=("$OUTPUT_DIR/$(basename "$img")"); done
staged_xt_image_hashes=$(hash_xt_image_set "${STAGED_XT_IMAGES[@]}")
[ "$staged_xt_image_hashes" = "$validated_xt_image_hashes" ] \
	|| die "a staged ATtiny202 image differs from the image exercised by its gates and soak"

# Checksums over the images. Named EXPLICITLY, never globbed: `sha256sum ./*.hex`
# would faithfully record whatever happens to be sitting in the staging
# directory, so a stale image left by an earlier run would be checksummed,
# committed and published as part of this release. The verifier would then
# confirm it -- the producer and the verifier sharing one blind spot is the
# §14.8 hole from the writing side. Every family is byte-bound above before this
# checksum file can be accepted as release evidence.
release_basenames=()
for img in "${IMAGES[@]}"; do release_basenames+=("$(basename "$img")"); done

# Stage the required non-image artifacts beside the images and prove each is the
# tracked source byte for byte. No compiler produces these, so the copy IS the
# only place their identity can be established -- and they are checksummed in
# the same file, under the same signature, as the firmware they program.
for helper_base in "${RELEASE_HELPER_NAMES[@]}"; do
	helper_src="$REPO_ROOT/${RELEASE_HELPER_SOURCE[$helper_base]}"
	cp -p -- "$helper_src" "$OUTPUT_DIR/$helper_base" \
		|| die "could not stage required release artifact $helper_base"
	staged_helper_digest=$(sha256sum -- "$OUTPUT_DIR/$helper_base") \
		|| die "could not hash staged release artifact $helper_base"
	source_helper_digest=$(sha256sum -- "$helper_src") \
		|| die "could not hash release artifact source ${RELEASE_HELPER_SOURCE[$helper_base]}"
	[ "${staged_helper_digest%% *}" = "${source_helper_digest%% *}" ] \
		|| die "staged release artifact $helper_base differs from ${RELEASE_HELPER_SOURCE[$helper_base]}"
done

( cd "$OUTPUT_DIR" && sha256sum -- "${release_basenames[@]}" \
	"${RELEASE_HELPER_NAMES[@]}" > SHA256SUMS ) \
	|| die "could not checksum the staged release images and artifacts"

# ...and assert the staging directory holds exactly that set and nothing else,
# because publication (.github/workflows/release.yml) uploads by glob.
shopt -s nullglob dotglob
staged=()
for f in "$OUTPUT_DIR"/*.hex; do staged+=("$(basename "$f")"); done
shopt -u nullglob dotglob
staged_sorted=$(printf '%s\n' "${staged[@]}" | LC_ALL=C sort)
wanted_sorted=$(printf '%s\n' "${release_basenames[@]}" | LC_ALL=C sort)
if [ "$staged_sorted" != "$wanted_sorted" ]; then
	diff -u <(printf '%s\n' "$wanted_sorted") <(printf '%s\n' "$staged_sorted") >&2 || true
	die "$OUTPUT_DIR holds images that are not part of this release (stale output?)."
fi
ok "wrote SHA256SUMS over ${#IMAGES[@]} images and ${#RELEASE_HELPER_NAMES[@]} required artifact(s); staging directory holds exactly that image set."

# Copy evidence. The per-combo soak logs and build/target logs are small and kept
# in full. The exhaustive test-long transcript is large (100s of KB), duplicates
# the detailed diagnostics of reproducible gates, and is transient diagnostic
# output rather than required release evidence. Retain an exact source-bound PASS
# record plus selected terminal output; tag CI independently reruns test-long,
# but its hosted job log is subject to platform retention and is not an archive.
for f in "$EVID"/*.log; do
	case "$(basename "$f")" in
		test-long.log)
			{ echo "# test-long retained result"; echo; \
			  printf 'TEST_LONG_RESULT format=1 status=pass source_commit=%s target=test-long strict_tools=1 mutation_allow_skip=0\n' "$GIT_SHA"; \
			  echo; echo "# Selected terminal output (the full transcript is not retained)."; echo; \
			  grep -nE '^(===|--- |OK:|FAIL|cbmc:|MISRA|golden-model|killed|survived|mutant)' "$f" || true; \
			  echo; echo "# --- last 20 lines ---"; tail -20 "$f"; \
			} > "$OUTPUT_DIR/evidence/test-long.summary.txt" ;;
		*) cp -p "$f" "$OUTPUT_DIR/evidence/" ;;
	esac
done
cp -p -- "$PIC12F675_QUALIFIED_MATRIX" \
	"$OUTPUT_DIR/evidence/pic12f675-qualified-matrix.json" \
	|| die "could not stage the qualified PIC12F675 matrix manifest"
staged_pic12f675_matrix_record=$(python3 "$PIC12F675_MATRIX_EVIDENCE" verify-release \
	--manifest "$OUTPUT_DIR/evidence/pic12f675-qualified-matrix.json" \
	--qualification-log "$OUTPUT_DIR/evidence/pic12f675-qualification.log" \
	--release-dir "$OUTPUT_DIR" --fw-base "$FW_BASE" \
	--tag "$PIC12F675_TAG" \
	--expected-manifest-sha256 "$pic12f675_matrix_sha256") \
	|| die "staged PIC12F675 images are not bound to the qualified matrix"
[ "$staged_pic12f675_matrix_record" = "$qualified_pic12f675_matrix_record" ] \
	|| die "staged PIC12F675 matrix identity differs from qualification"
staged_pic12f675_matrix_sha256=$(sha256sum -- \
	"$OUTPUT_DIR/evidence/pic12f675-qualified-matrix.json") \
	|| die "could not hash the staged PIC12F675 matrix manifest"
staged_pic12f675_matrix_sha256=${staged_pic12f675_matrix_sha256%% *}
[ "$staged_pic12f675_matrix_sha256" = "$pic12f675_matrix_sha256" ] \
	|| die "staged PIC12F675 matrix manifest differs from retained qualification"
staged_resource_tables_sha256=$(sha256sum -- \
	"$OUTPUT_DIR/evidence/resource-tables.log") \
	|| die "could not hash staged resource evidence"
staged_resource_tables_sha256=${staged_resource_tables_sha256%% *}
[ "$staged_resource_tables_sha256" = "$resource_tables_sha256" ] \
	|| die "staged resource evidence differs from final-candidate measurement"

# Compact machine-readable attestation. The verifier parses this as data (never
# sources it), then cross-checks it against the canonical evidence inventory,
# every terminal soak record, and the human-readable manifest.
{
	printf 'format=3\n'
	printf 'version=%s\n' "$VERSION"
	printf 'release_mode=%s\n' "$RELEASE_MODE"
	printf 'source_commit=%s\n' "$GIT_SHA"
	printf 'source_dirty=%s\n' "$GIT_DIRTY"
	printf 'soak_duration_ms=%s\n' "$SOAK_DURATION_MS"
	printf 'soak_liveness_interval_ms=%s\n' "$SOAK_LIVENESS_INTERVAL_MS"
	printf 'soak_combination_count=%s\n' "$NCOMBOS"
	printf 'pic12f675_matrix_sha256=%s\n' "$pic12f675_matrix_sha256"
	printf 'resource_tables_sha256=%s\n' "$resource_tables_sha256"
} > "$OUTPUT_DIR/QUALIFICATION"

# --- per-image facts for the manifest (target, clock, fuses, flashing cmd) ----
# Echoes a markdown table row for one image path.
img_row() {
	local path="$1" base; base=$(basename "$path")
	local sha; sha=$("$AWK" -v f="$base" '$2==f{print $1}' "$OUTPUT_DIR/SHA256SUMS")
	# Flash usage is read from the build ELF (the HEX does not carry section
	# sizes avr-size can total); the ELF is still present in $AVR_BUILD_DIR when
	# the manifest is generated. PIC usage stays n/a (XC8 reports words, not bytes).
	local elf="$AVR_BUILD_DIR/${base%.hex}.elf"
	local mcu clk fuses flashcmd prog amcu used="n/a"
	# Every arm below matches the MANDATORY MCU field of the canonical basename
	# (<prefix>-<mcu>-<stage>), so the arms are mutually exclusive and order
	# carries no meaning. That is a change worth noticing: this used to be an
	# ORDER-DEPENDENT chain ending in a bare `*.hex` ATtiny13a fallback, because
	# a bare `bypass_cd4053.hex` was the ATtiny13a image. Any unrecognized name
	# fell through to that arm and produced a row confidently labelling foreign
	# firmware as an ATtiny13a with AVR fuse bytes. With the MCU always present
	# the fallback becomes a hard error instead.
	case "$base" in
		${FW_BASE}-${PIC10F320_TAG}-*.hex)
			mcu="PIC10F320"; clk="${PIC10F320_CLK_MHZ} MHz (HFINTOSC)"; fuses="CONFIG word embedded in HEX"
			# XC8 reports program space in WORDS, not bytes; the figure comes from
			# this run's own build log, so it can never be a stale hand-copied number.
			used=$("$AWK" -v f="$base" '$0 ~ ("/" f " :") { for (i = 1; i <= NF; i++) if ($i == "words") { print $(i-1) " / '"$PIC10F320_FLASH_WORDS"' words"; exit } }' \
				"$EVID/build-pic10f320.log" 2>/dev/null)
			flashcmd="pk2cmd -PPIC10F320 -F$base -M -Y -R" ;;
		${FW_BASE}-${PIC10F322_TAG}-*.hex)
			mcu="PIC10F322"; clk="${PIC10F322_CLK_MHZ} MHz (HFINTOSC)"; fuses="CONFIG word embedded in HEX"
			flashcmd="pk2cmd -PPIC10F322 -F$base -M -Y -R   (or: make pic10f322-program VARIANT=<v>)" ;;
		${FW_BASE}-${PIC12F675_TAG}-*.hex)
			mcu="PIC12F675"; clk="${PIC12F675_CLK_MHZ} MHz (INTOSC, factory OSCCAL)"; fuses="CONFIG word embedded in HEX"
			# XC8 reports program space in WORDS; the figure comes from this run's
			# own build log, so it can never be a stale hand-copied number.
			used=$("$AWK" -v f="$base" '$0 ~ ("/" f " :") { for (i = 1; i <= NF; i++) if ($i == "words") { print $(i-1) " / '"$PIC12F675_FLASH_WORDS"' words"; exit } }' \
				"$EVID/build-pic12f675.log" 2>/dev/null)
			# A writer may erase factory trim even when the image leaves it untouched.
			# Publish no per-image shortcut: the generated procedure below performs the
			# mandatory baseline, immediate comparison, write and retained readback.
			flashcmd="" ;;
		${FW_BASE}-${XT_TAG}-*.hex)
			mcu="ATtiny202"; clk="${XT_CLK_MHZ} MHz (internal, OSCCFG 16 MHz / 8)"
			# AVR8X replaces lfuse/hfuse with seven individually named memories;
			# enumerate them rather than inventing a two-byte summary.
			fuses=""
			for f in $XT_FUSE_NAMES; do
				fuses="${fuses}${fuses:+ }$f=${XT_FUSE[$f]}"
			done
			# From this run's own build log, like the PIC10F320 arm: the figure is
			# never a stale hand-copied number, and avr-size cannot total it here
			# (binutils 2.26 reports "Device: Unknown" for avrxmega3 parts).
			used=$("$AWK" -v f="$base" '$0 ~ ("/" f " :") { for (i = 1; i <= NF; i++) if ($i == "B") { print $(i-1) " B"; exit } }' \
				"$EVID/build-avr-xt.log" 2>/dev/null)
			flashcmd="avrdude -c $XT_PROGRAMMER -P <port> -p $XT_AVRDUDE_PART"
			for f in $XT_FUSE_NAMES; do
				flashcmd="$flashcmd -U $f:w:${XT_FUSE[$f]}:m"
			done
			flashcmd="$flashcmd -U flash:w:$base:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)" ;;
		${FW_BASE}-attiny85-*.hex|${FW_BASE}-attiny45-*.hex)
			case "$base" in
				${FW_BASE}-attiny85-*.hex) mcu="ATtiny85"; amcu="attiny85" ;;
				*)                         mcu="ATtiny45"; amcu="attiny45" ;;
			esac
			# From the Makefile's part_<n>, like the other four arms. The
			# literals this replaces were the only programmer names in the
			# manifest not taken from Makefile truth -- and AVRDUDE_PART_X5 was
			# built above and then read by nobody, so the whole `mkv` preamble
			# was validating a value it discarded.
			prog=${AVRDUDE_PART_X5[${amcu#attiny}]:-}
			[ -n "$prog" ] \
				|| die "no avrdude part name for $amcu: TINYX5 and this manifest arm disagree"
			clk="1.0 MHz"; fuses="lfuse=$LFUSE_X5 hfuse=$HFUSE_X5"
			used=$("$AVR_SIZE" --mcu="$amcu" -C "$elf" 2>/dev/null | "$AWK" '/^Program:/{print $2" B"; exit}')
			flashcmd="avrdude -c <prog> -p $prog -U lfuse:w:$LFUSE_X5:m -U hfuse:w:$HFUSE_X5:m -U flash:w:$base:i" ;;
		${FW_BASE}-${ATTINY13A_MCU}-*.hex)
			mcu="ATtiny13a"; clk="1.2 MHz"; fuses="lfuse=$LFUSE hfuse=$HFUSE"
			used=$("$AVR_SIZE" --mcu=attiny13a -C "$elf" 2>/dev/null | "$AWK" '/^Program:/{print $2" B"; exit}')
			flashcmd="avrdude -c <prog> -p $AVRDUDE_PART -U lfuse:w:$LFUSE:m -U hfuse:w:$HFUSE:m -U flash:w:$base:i" ;;
		*) die "release image '$base' names no MCU this manifest generator knows; refusing to describe it" ;;
	esac
	printf '| `%s` | %s | %s | %s | %s | `%s` |\n' "$base" "$mcu" "$clk" "${used:-n/a}" "$fuses" "$sha"
	[ -z "$flashcmd" ] || printf '%s\t%s\n' "$base" "$flashcmd" >> "$WORK/flashcmds.txt"
}

# Soak evidence summary table.
soak_table() {
	local name f
	local -a lines
	for name in "${SOAK_NAMES[@]}"; do
		f="$OUTPUT_DIR/evidence/soak-$name.log"
		mapfile -t lines < <(grep "^SOAK PASS: $SOAK_DURATION_MS ms " "$f" || true)
		[ "${#lines[@]}" -eq 1 ] \
			|| die "cannot render one exact soak summary for $name"
		printf '| %s | %s |\n' "$name" "${lines[0]}"
	done
}

REL_BANNER=""
[ "$DRY_RUN" -eq 1 ] && REL_BANNER=$'> **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.\n'
# An express release is publishable, so its banner must not read as a warning
# against publication -- it must say precisely which evidence is shorter. The
# leading sentinel is what scripts/verify-release-qualification.sh and the tag
# workflow match on, so it is a fixed string; only the hours interpolate.
# The trailing newline is appended after the substitution, which strips them:
# the banner is a Markdown blockquote and needs the blank line the dry-run
# banner also carries, or the paragraph that follows joins the quote.
[ "$EXPRESS" -eq 1 ] && REL_BANNER="$(printf '> **EXPRESS QUALIFICATION -- SHORTENED SOAK.** Every gate below ran in full; the parallel soak ran %s h per combination instead of 24 h.' "$hours")"$'\n'

: > "$WORK/flashcmds.txt"
{
	printf '# Firmware release %s\n\n' "$VERSION"
	[ -n "$REL_BANNER" ] && printf '%s\n' "$REL_BANNER"
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'Prebuilt firmware rehearsal images; not fully validated. Verify integrity with\n'
	elif [ "$EXPRESS" -eq 1 ]; then
		printf 'Prebuilt firmware images; every release gate passed, with the shortened soak\n'
		printf 'recorded above and in QUALIFICATION. Verify integrity with\n'
	else
		printf 'Prebuilt, fully-validated firmware images. Verify integrity with\n'
	fi
	printf '`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.\n\n'
	printf 'This bundle also ships `flash-pic12f675.py`, covered by the same checksum\n'
	printf 'file and signature. The PIC12F675 is not a raw write target: pass its image\n'
	printf 'to that helper, never straight to a programmer. See "PIC12F675 programming".\n\n'
	release_render_scope

	printf '## PIC10F320 -- the constrained target\n\n'
	printf 'The PIC10F320 has 256 words of flash, half the PIC10F322. The pure/result-struct\n'
	printf 'architecture every other target compiles into its shipping image does not fit, so\n'
	printf 'its firmware inlines the debounce algorithm into `main()` by hand. It is fully\n'
	printf 'release-gated -- firmware-to-core equivalence against the same verified\n'
	printf '`src/bypass_pure.c`, real-HEX lock-step, host and target fault injection, exact\n'
	printf 'firmware line coverage, and its own %s-h soak per output stage -- but the\n' "$hours"
	printf 'inlining seam means its architecture is not identical to the other targets.\n'
	printf 'It is the constrained exception, not evidence that the reference architecture\n'
	printf 'fits 256 words.\n\n'
	if [ -f "$REPO_ROOT/DESIGN_DOCUMENTATION.adoc" ]; then
		# Absolute and tag-pinned: this file is both committed at
		# release/<version>/MANIFEST.md and published verbatim as the GitHub
		# Release body, where '../../' does not resolve. The tag does not exist
		# yet at generation time -- it is created from this very run -- so the
		# link goes live when the release is pushed. (Under --dry-run no tag is
		# ever created, so the link will 404; the dry-run banner already says
		# the output is not a real release.)
		printf 'Full detail: [DESIGN_DOCUMENTATION.adoc](%s/blob/%s/DESIGN_DOCUMENTATION.adoc#pic10f320-architecture).\n\n' \
			"$REPO_URL" "$VERSION"
	fi
	printf 'Its images follow the same `%s-<mcu>-<output stage>.hex` scheme as every\n' "$FW_BASE"
	printf 'other target (`%s-%s-<output stage>.hex`); the imported `bypass_mcu_` prefix\n' "$FW_BASE" "$PIC10F320_TAG"
	printf 'it shipped with through v0.9.7 is gone as of v0.9.8.\n\n'

	printf '## Provenance\n\n'
	printf -- '- **Version / tag:** %s\n' "$VERSION"
	printf -- '- **Release mode:** %s\n' "$RELEASE_MODE"
	printf -- '- **Source commit:** `%s`\n' "$GIT_SHA"
	printf -- '- **Soak duration per combination:** %s ms\n' "$SOAK_DURATION_MS"
	printf -- '- **Soak combinations:** %s\n' "$NCOMBOS"
	printf -- '- **PIC12F675 qualified matrix:** `evidence/pic12f675-qualified-matrix.json` (SHA-256 `%s`)\n' \
		"$pic12f675_matrix_sha256"
	printf -- '- **Final resource evidence:** `evidence/resource-tables.log` (SHA-256 `%s`)\n' \
		"$resource_tables_sha256"
	[ "$GIT_DIRTY" -eq 1 ] && printf -- '- **WARNING:** built from a DIRTY tree (uncommitted changes not captured by the SHA).\n'
	printf -- '- **Built:** %s by `%s` on `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-?}" "$(uname -srm)"
	release_render_validation "$hours"
	printf -- '- **Release set:** %d images, checked against the canonical `RELEASE_IMAGES` set declared in the Makefile -- not against whatever the build happened to produce.\n' "${#IMAGES[@]}"
	printf '\n'

	printf '## Toolchain\n\n'
	printf -- '| tool | version |\n|---|---|\n'
	printf -- '| avr-gcc | %s |\n' "$TC_AVR_GCC"
	printf -- '| binutils-avr (objcopy) | %s |\n' "$TC_AVR_BU"
	printf -- '| avr-libc (pkg) | %s |\n' "$TC_AVR_LIBC"
	printf -- '| host cc | %s |\n' "$TC_HOST_CC"
	release_render_pic_toolchain_rows "$PIC_CC" "$TC_XC8_322" \
		"$PIC10F320_CC" "$TC_XC8_320" "$PIC_DFP" "$PIC10F320_DFP"
	printf -- '| gpsim | %s |\n' "$TC_GPSIM"
	printf -- '| libsimavr-dev (pkg) | %s |\n' "$TC_SIMAVR"
	printf -- '| cppcheck | %s |\n' "$TC_CPPCHECK"
	printf -- '| cbmc | %s |\n' "$TC_CBMC"
	printf -- '| clang | %s |\n' "$TC_CLANG"
	printf -- '| python3 | %s |\n' "$TC_PY"
	printf -- '| PIC12F675 Python | %s |\n\n' "$TC_PIC12F675_PY"

	printf '## Images\n\n'
	printf '| image | MCU | clock | flash used | fuses / config | sha256 |\n'
	printf '|---|---|---|---|---|---|\n'
	for img in "${IMAGES[@]}"; do img_row "$OUTPUT_DIR/$(basename "$img")"; done
	printf '\n> The ATtiny13a images are not soak-tested directly (simavr cannot model\n'
	printf '> its watchdog reset); they are covered by the full test-long suite and by\n'
	printf '> the soak of the core-identical tinyx5 family. See DESIGN_DOCUMENTATION.adoc.\n\n'

	release_render_flashing "$WORK/flashcmds.txt" "$VERSION"

	printf '## Soak evidence\n\n'
	printf '| combo | result |\n|---|---|\n'
	soak_table
	printf '\n'

	printf '## Reproducing these images\n\n'
	printf 'Check the images this tag *builds* against the committed checksums. A\n'
	printf 'freshly built HEX lands under %s, not\n' \
		"$(printf '%s\n' $RELEASE_IMAGE_DIRS | sed 's#^#`#; s#$#/`#' | paste -sd' ' -)"
	printf 'in this release directory, so the checksum list must be run against those\n'
	printf 'fresh bytes (running it from the repo root would just re-verify the\n'
	printf 'committed copies against themselves).\n\n'
	printf '```\n'
	release_render_reproduction_commands "$VERSION" "$RELEASE_IMAGE_DIRS" \
		"$AVR_BUILD_DIR" "$XT_BUILD_DIR" "$PIC10F322_BUILD_DIR" \
		"$PIC10F320_BUILD_DIR" "$PIC12F675_BUILD_DIR" \
		"$PIC_CC" "$PIC_DFP" "$PIC10F320_CC" "$PIC10F320_DFP"
	printf '```\n'
	printf 'A passing verifier proves four things agree: the committed files, the checksum\n'
	printf 'entries, the freshly built files, and the canonical `RELEASE_IMAGES` set the\n'
	printf 'Makefile declares. The fourth is what makes the first three mean something --\n'
	printf 'three sets derived by globbing the same directories agree perfectly on a\n'
	printf 'release that is missing an entire MCU.\n'
	printf 'The tag-triggered CI (.github/workflows/release.yml) runs this exact check on a\n'
	printf 'clean runner and fails the release on any mismatch.\n'
} > "$OUTPUT_DIR/MANIFEST.md"
ok "wrote MANIFEST.md"

# Per-version README (concise; points at the top-level release/README.md).
{
	printf '# %s\n\n' "$VERSION"
	[ -n "$REL_BANNER" ] && printf '%s\n' "$REL_BANNER"
	printf 'Prebuilt firmware for %s. See **MANIFEST.md** for provenance, the per-image\n' "$VERSION"
	printf 'fuse bytes / flashing commands, **QUALIFICATION** for the machine-verified\n'
	printf 'release gate, and evidence/ for the retained logs. See the top-level\n'
	printf '[release/README.md](../README.md) for the trust model and verification steps.\n\n'
	printf '**PIC12F675 is not a raw write target.** Its per-device factory OSCCAL and\n'
	printf 'CONFIG BG trim live in memory a programmer erases, and a device that loses\n'
	printf 'either still appears to work. Pass its image to `flash-pic12f675.py` in this\n'
	printf 'directory -- covered by the same SHA256SUMS -- never straight to a programmer.\n\n'
	printf 'Quick verify:\n```\ncd release/%s && sha256sum -c SHA256SUMS\n```\n' "$VERSION"
	printf '\nVerify the required checksum signature first:\n'
	printf '```\ngpg --verify SHA256SUMS.asc SHA256SUMS\n```\n'
} > "$OUTPUT_DIR/README.md"

if [ "$DRY_RUN" -eq 1 ]; then qualification_args=(--allow-dry-run); else qualification_args=(); fi
scripts/verify-release-qualification.sh "${qualification_args[@]}" "$OUTPUT_DIR" "$VERSION" \
	|| die "staged release qualification failed verification"
ok "release qualification metadata and evidence verified."

# Step 0 validated the bounded current-release declarations against the
# canonical set the Makefile PREDICTS a release will contain. Re-validate them
# here against what was actually staged, so the last documentation check before
# the artifact commit and the tag is that the designated current documents and
# one directory agree on the same inventory.
release_validate_staged_documentation "$REPO_ROOT" "$OUTPUT_DIR" "$VERSION" \
	|| die "staged release inventory does not match the bounded current-release declarations"
ok "bounded current-release declarations match the staged inventory."

# Commit message for the human to use verbatim (git commit -F ...).
release_render_commit_message "$VERSION" "$RELEASE_MODE" "$GIT_SHORT" \
	"${#IMAGES[@]}" "$hours" > "$OUTPUT_DIR/commit_msg.txt"

# Fold evidence in and finish.
ls -1 "$OUTPUT_DIR" >&2

# ============================================================================
# 5. HAND OFF -- print the git + signing recipe (this script runs NOTHING below)
# ============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
	section "DRY RUN complete"
	warn "This was a rehearsal with a short soak. Output staged at $OUTPUT_DIR is NOT a real release."
	warn "Re-run WITHOUT --dry-run (full 24-h soak) to produce a publishable release."
	exit 0
fi
# An express release is published like any other, so the recipe below is
# printed. Say once more what it is, at the point the operator decides to sign.
if [ "$EXPRESS" -eq 1 ]; then
	warn "EXPRESS release: the soak ran ${hours} h per combination, not 24 h. Every other gate ran in full."
	warn "MANIFEST.md carries the express banner and QUALIFICATION records release_mode=express; both are signed by the checksum signature below."
fi

# Everything below goes to STDOUT: the exact commands for the human to run.
cat <<EOF

$BOLD========== release $VERSION staged -- next steps (run by hand) ==========$RST

Review the staging dir, then sign + commit + tag + push. The pushed tag triggers
.github/workflows/release.yml, which reproduces the image hashes on a clean
runner and publishes the GitHub Release.

The release commit must contain ONLY $OUTPUT_DIR. Tag CI requires its sole
parent to be the source commit qualified above and rejects every changed path
outside release/$VERSION/, so changelog/status documentation is finalized in the
PRECEDING commit -- as it already was, or this run would not have started.
Until the tag below is pushed, main carries the $VERSION contract while
release/$VERSION/ is unpublished; if you abandon or postpone the release from
here, revert or correct that source-finalization commit rather than leaving the
declaration standing. Ensure the remote protects v* tags from update and
deletion; CI rechecks the remote target immediately before publication, but no
workflow can make two separate GitHub API operations atomic.

  # 1. review
  git status
  less $OUTPUT_DIR/MANIFEST.md

  # 2. sign the checksums (detached, ASCII-armored) -- adds SHA256SUMS.asc
  gpg --local-user $RELEASE_SIGNING_FINGERPRINT --armor --detach-sign $OUTPUT_DIR/SHA256SUMS
  # 3. commit the whole release dir (uses the generated message)
  git add $OUTPUT_DIR
  git commit -F $OUTPUT_DIR/commit_msg.txt

  # 4. create a SIGNED, annotated tag on that commit
  git tag -s -u $RELEASE_SIGNING_FINGERPRINT $VERSION -m "Firmware release $VERSION"

  # 5. push the commit and the tag
  git push
  git push origin $VERSION

EOF
ok "done. Nothing was committed, tagged, or pushed -- that is yours to do."
