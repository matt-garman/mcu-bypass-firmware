#!/usr/bin/env bash
#
# Mutation testing for the bypass firmware (core + output-driver variants).
#
# WHY THIS EXISTS
# ---------------
# A passing test suite proves the tests PASS on correct code; it does not prove
# the tests would FAIL on broken code. Mutation testing closes that gap: it
# injects a small, deliberate fault ("mutant") into the PRODUCTION sources (the
# pure core, any per-MCU shell -- AVR classic, AVR-XT, either PIC -- the output
# drivers, or bypass_config.h), rebuilds, and runs a fast test target. A correct,
# adequate suite must DETECT the fault -- the test target must FAIL (the mutant
# is "killed"). A mutant that survives (tests still pass) marks a real hole in
# the suite.
#
# Core/config mutants map to the single fast variant target `test-sim-cd4053_simple-attiny13a`
# (the core debounce/WDT logic is shared by every variant, so one variant
# suffices to kill them). Output-driver mutants map to their own variant target
# (`test-sim-tq2_l2_5v_relay-attiny13a` / `test-sim-cd4053_with_mute-attiny13a` / `test-sim-cd4053_simple-attiny13a`).
#
# This operates entirely on a throwaway COPY of the tree; it never modifies the
# real sources. It is wired into `make test-mutation` and is intentionally NOT
# part of the default `make test` (it rebuilds the firmware once per mutant).
#
# Each mutation lists the fast `make` target expected to kill it, so the
# mutation->test mapping is explicit and the run stays quick.
#
# A note on self-referential oracles: the host golden-model tests pull
# RELEASE_THRESH/PRESSED_THRESH from bypass_config.h (the single source of
# truth), so they intentionally CANNOT catch a threshold change (expectation and
# code move together). The threshold mutants below are therefore mapped to
# `test-sim-attiny13a`, where the simavr noise test asserts a HARD-CODED toggle count and
# the lock-step co-sim compares the real binary against an independent model.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

# Wall-clock ceiling on a single mutant checker. Use the unset-only default:
# an explicitly empty value is invalid and must not silently become 900.
mutation_timeout_is_valid() {
    local value=$1 whole fraction canonical_whole whole_number
    [[ $value =~ ^[0-9]+([.][0-9]{1,3})?$ ]] || return 1
    whole=${value%%.*}
    if [[ $value == *.* ]]; then fraction=${value#*.}; else fraction=0; fi
    canonical_whole=$whole
    while [ "${#canonical_whole}" -gt 1 ] && [[ $canonical_whole == 0* ]]; do
        canonical_whole=${canonical_whole#0}
    done
    [ "${#canonical_whole}" -le 5 ] || return 1
    whole_number=$((10#$canonical_whole))
    [ "$whole_number" -lt 86400 ] \
        || { [ "$whole_number" -eq 86400 ] && [[ ! $fraction =~ [1-9] ]]; } \
        || return 1
    [ "$whole_number" -gt 0 ] || [[ $fraction =~ [1-9] ]]
}
resolve_mutation_timeout() {
    local value
    if [ "${MUTATION_TIMEOUT_S+x}" = x ]; then value=$MUTATION_TIMEOUT_S; else value=900; fi
    mutation_timeout_is_valid "$value" || {
        echo "ERROR: MUTATION_TIMEOUT_S must be 0.001..86400 seconds with at most three fractional digits (got '$value')" >&2
        return 2
    }
    printf '%s\n' "$value"
}
if ! MUTATION_TIMEOUT_S=$(resolve_mutation_timeout); then exit 2; fi
for mutation_command in timeout setsid ps; do
    command -v "$mutation_command" >/dev/null 2>&1 || {
        echo "ERROR: $mutation_command is required for bounded mutation process cleanup" >&2
        exit 2
    }
done

# Missing PIC tools normally make the PIC mutation subset an explicit partial
# local run. Strict/full-tool contexts default to failure unless the caller
# explicitly authorizes a partial mutation run.
source "$SCRIPT_DIR/mutation_policy.sh"
MUTATION_ALLOW_SKIP=$(resolve_mutation_allow_skip)
policy_rc=$?
[ "$policy_rc" -eq 0 ] || exit "$policy_rc"
source "$SCRIPT_DIR/mutation_accounting.sh"
# The sandbox builder, shared with test/test_pic_rebuild.sh -- the other harness
# that copies the repo into a mktemp tree and runs Make inside it. It used to
# enumerate its prerequisites by hand, so a new one had to be added twice; the
# allowlist walk now serves both. See test/scratch_tree.sh for the two
# constraints (allowlist, no Git) that any edit to it must preserve.
source "$SCRIPT_DIR/scratch_tree.sh"

readonly MUTATION_EXPECTED_CORE=32
readonly MUTATION_EXPECTED_XT=23
readonly MUTATION_EXPECTED_PIC_GPSIM=6
readonly MUTATION_EXPECTED_PIC_TARGET=10
readonly MUTATION_EXPECTED_PIC_SOAK=1
readonly MUTATION_EXPECTED_PIC320_HOST=30
readonly MUTATION_EXPECTED_PIC320_TOOL=12
readonly MUTATION_EXPECTED_PIC12F675=23
readonly MUTATION_EXPECTED_TOTAL=137

# PIC build/test knobs (mirror the Makefile defaults; override via env). Used by
# the PIC-shell mutants and their toolchain probe below.
GPSIM="${GPSIM:-gpsim}"
MUTATION_MAKE="${MUTATION_MAKE:-make}"
PIC_SOAK_CXX="${PIC_SOAK_CXX:-c++}"
PIC10F320_SOAK_CXX="${PIC10F320_SOAK_CXX:-$PIC_SOAK_CXX}"
PIC12F675_MUTATION_HOSTCC=${HOSTCC:-cc}
export PIC_SOAK_CXX PIC10F320_SOAK_CXX
if ! PIC12F675_MUTATION_CC=${PIC_CC:-$("$MUTATION_MAKE" -s --no-print-directory \
        -C "$PROJ_DIR" print-PIC_CC)} \
        || ! PIC12F675_MUTATION_DFP=${PIC_DFP:-$("$MUTATION_MAKE" -s \
        --no-print-directory -C "$PROJ_DIR" print-PIC_DFP)} \
        || ! PIC10F320_MUTATION_CC=${PIC10F320_CC:-$("$MUTATION_MAKE" -s \
        --no-print-directory -C "$PROJ_DIR" print-PIC10F320_CC)} \
        || ! PIC10F320_MUTATION_DFP=${PIC10F320_DFP:-$("$MUTATION_MAKE" -s \
        --no-print-directory -C "$PROJ_DIR" print-PIC10F320_DFP)} \
        || ! PIC12F675_MUTATION_PYTHON=${PIC12F675_PYTHON:-$("$MUTATION_MAKE" -s \
        --no-print-directory -C "$PROJ_DIR" print-PIC12F675_PYTHON)}; then
    echo "ERROR: could not resolve PIC mutation tool inputs from Make" >&2
    exit 2
fi

# The PIC10F322 image the two PIC-shell lanes drive, resolved ONCE from the
# Makefile rather than recomposed from restated defaults.
#
# It used to be spelled "$PIC10F322_BUILD_DIR/${FW_BASE}-${PIC10F322_TAG}-<v>.hex"
# from three env-defaulted variables. The restatements in
# scripts/make-release.sh and test/test_pic_build.sh are deliberate -- they are
# independent opinions that exist to be cross-checked against Makefile truth --
# but these two cross-checked nothing and only needed a path, so a rename could
# move the image out from under them with nothing to notice. When that happens
# the lane does not fail: `[ -f "$hex" ]` is false, the mutant returns the
# infrastructure-error status, and the PIC subset degrades to a skip.
#
# Resolved by asking which release image carries the wanted stage, so a stage
# that no longer exists fails HERE, once, by name -- not as a missing file per
# mutant.
#
# --no-print-directory is REQUIRED, not decorative, and `-s` does NOT cover it.
# GNU Make turns on -w in a sub-make and then propagates a literal `w` in
# MAKEFLAGS; an explicit -w inherited that way OVERRIDES -s, so the capture
# below silently becomes three lines -- "Entering directory ...", the value,
# "Leaving directory ...". Whether that happens depends on how this suite was
# entered, which is why it hid for so long:
#
#   make test-long / make test-mutation  -> the worktree-serialization wrapper
#       re-execs with --no-print-directory, MAKEFLAGS is clean, resolution works
#   make release -> make-release.sh -> make test-long  -> that Make is a
#       sub-make, MAKEFLAGS carries `w`, and PIC10F322_BUILD_DIR came back with
#       the directory banner glued to it
#
# The corrupted path made `[ -f "$hex" ]` false in the probe below, which the
# summary reported as "PIC-shell mutants: SKIPPED (tools absent)" on a host with
# the whole PIC toolchain installed -- 15 mutants unenforced, blamed on an
# absent tool. Exactly the silent-shrink failure the comment above describes,
# reached through Make's output rather than through a rename. The whitespace
# guard is the fail-closed backstop: this resolution yields ONE bare path word,
# so anything else fails HERE, by name, instead of degrading to a skip.
PIC10F322_MUTATION_VARIANT="${PIC10F322_MUTATION_VARIANT:-cd4053_simple}"
resolve_pic10f322_mutation_hex() {
    local dir images matched
    dir=$("$MUTATION_MAKE" -s --no-print-directory -C "$PROJ_DIR" \
        print-PIC10F322_BUILD_DIR) || return 1
    images=$("$MUTATION_MAKE" -s --no-print-directory -C "$PROJ_DIR" \
        print-PIC10F322_RELEASE_IMAGES) || return 1
    [ -n "$dir" ] && [ -n "$images" ] || return 1
    case $dir in *[[:space:]]*) return 1 ;; esac
    matched=$(printf '%s\n' $images | grep -c -- "-${PIC10F322_MUTATION_VARIANT}\.hex$")
    [ "$matched" -eq 1 ] || return 1
    printf '%s/%s\n' "$dir" \
        "$(printf '%s\n' $images | grep -- "-${PIC10F322_MUTATION_VARIANT}\.hex$")"
}
if ! PIC10F322_MUTATION_HEX=$(resolve_pic10f322_mutation_hex); then
    echo "ERROR: cannot resolve the PIC10F322 ${PIC10F322_MUTATION_VARIANT} image" \
         "from the Makefile; either PIC10F322_RELEASE_IMAGES names no such output" \
         "stage, or print-PIC10F322_BUILD_DIR did not return one bare path word" >&2
    exit 1
fi
readonly PIC10F322_MUTATION_HEX
PIC_SOAK_GPSIM_INC="${PIC_SOAK_GPSIM_INC:-/usr/include/gpsim}"
PIC10F320_SOAK_GPSIM_INC="${PIC10F320_SOAK_GPSIM_INC:-$PIC_SOAK_GPSIM_INC}"
# Every mutant runs under this wall-clock ceiling; see mutation_bounded below.
#
# Why this exists: in v0.9.8 a renamed override left the classic-AVR WDT mutant
# asking for 2 s of simulated soak and silently getting the 24 h default. A local
# run sat in that ONE mutant for over ten hours before it was killed by hand, and
# both CI jobs reaching that row would have been cancelled at GitHub's 6 h job
# limit with nothing useful reported. Nothing in the harness bounded it.
#
# 900 s is deliberately loose. The mutant soak windows above are 2-2.5 s of
# simulated time and the slowest legitimate mutant is a full XC8 rebuild plus a
# gpsim run, so this is ~2 orders of magnitude of headroom -- tight enough to
# catch the 43,200x class of severance immediately, loose enough that it cannot
# become a source of flaky failures. Tighten it from measured runtimes later if
# that is ever worth doing; do not tighten it speculatively.
# SIGTERM at the deadline, SIGKILL 10 s later for anything that ignores it. Each
# outer timeout is also a session leader. That ownership boundary contains nested
# timeout process groups used by gpsim wrappers, which an outer group signal alone
# cannot reach.
#
# The exit status matters as much as the bound: expiry yields 124, which
# mutation_accounting.sh classifies as an infrastructure error, so a hung mutant
# is reported as ERROR. Without that classification a hang would exit nonzero and
# be recorded as KILLED -- a clean-looking run that measured nothing.
mutation_snapshot_processes() {
    MUTATION_PROCESS_SNAPSHOT=$(ps -eo pid=,pgid=,sid=) || return 1
}

mutation_process_has_env_entry() {
    local pid=$1 wanted_entry=$2 entry
    local -a entries=()
    # procfs mode bits can claim readability even when ptrace policy denies the
    # open. Redirect stderr before opening environ so unrelated protected
    # processes are skipped without polluting the mutation verdict.
    mapfile -d '' -t entries 2>/dev/null < "/proc/$pid/environ" || return 1
    for entry in "${entries[@]}"; do
        [ "$entry" = "$wanted_entry" ] && return 0
    done
    return 1
}

mutation_process_read_ownership_tokens() {
    local pid=$1 entry
    local -a entries=()
    MUTATION_PROCESS_WORKER_TOKEN=
    MUTATION_PROCESS_CHECKER_TOKEN=
    mapfile -d '' -t entries 2>/dev/null < "/proc/$pid/environ" || return 1
    for entry in "${entries[@]}"; do
        case "$entry" in
            MUTATION_WORKER_TOKEN=*)
                MUTATION_PROCESS_WORKER_TOKEN=${entry#MUTATION_WORKER_TOKEN=}
                ;;
            MUTATION_CHECKER_TOKEN=*)
                MUTATION_PROCESS_CHECKER_TOKEN=${entry#MUTATION_CHECKER_TOKEN=}
                ;;
        esac
    done
}

mutation_env_entry_is_owned() {
    local wanted_entry=$1 pid pgid sid
    mutation_snapshot_processes || return 2
    while read -r pid pgid sid; do
        mutation_process_has_env_entry "$pid" "$wanted_entry" && return 0
    done <<< "$MUTATION_PROCESS_SNAPSHOT"
    return 1
}

mutation_signal_env_entry_groups() {
    local wanted_entry=$1 signal=$2 pid pgid sid
    local -A seen=()
    mutation_env_entry_is_owned "$wanted_entry" || return $?
    while read -r pid pgid sid; do
        mutation_process_has_env_entry "$pid" "$wanted_entry" || continue
        [[ -n ${seen["$pgid"]+x} ]] && continue
        seen["$pgid"]=1
        kill -"$signal" -- "-$pgid" 2>/dev/null || true
    done <<< "$MUTATION_PROCESS_SNAPSHOT"
}

mutation_session_has_processes() {
    local wanted_sid=$1 pid pgid sid
    mutation_snapshot_processes || return 2
    while read -r pid pgid sid; do
        [ "$sid" = "$wanted_sid" ] && return 0
    done <<< "$MUTATION_PROCESS_SNAPSHOT"
    return 1
}

mutation_session_is_owned() {
    local wanted_sid=$1 wanted_token=$2 pid pgid sid found=0
    mutation_snapshot_processes || return 3
    while read -r pid pgid sid; do
        [ "$sid" = "$wanted_sid" ] || continue
        found=1
        mutation_process_has_env_entry "$pid" \
            "MUTATION_CHECKER_TOKEN=$wanted_token" && return 0
    done <<< "$MUTATION_PROCESS_SNAPSHOT"
    [ "$found" -eq 0 ] && return 1
    return 2
}

mutation_signal_session_groups() {
    local wanted_sid=$1 wanted_token=$2 signal=$3 pid pgid sid
    local -A seen=()
    mutation_session_is_owned "$wanted_sid" "$wanted_token" || return $?
    while read -r pid pgid sid; do
        [ "$sid" = "$wanted_sid" ] || continue
        [[ -n ${seen["$pgid"]+x} ]] && continue
        seen["$pgid"]=1
        kill -"$signal" -- "-$pgid" 2>/dev/null || true
    done <<< "$MUTATION_PROCESS_SNAPSHOT"
}

mutation_terminate_checker_session() {
    local sid=$1 token=$2 attempt state signal_rc
    [[ $sid =~ ^[1-9][0-9]*$ && $token =~ ^checker-session[.][A-Za-z0-9]+$ ]] || return 1
    for ((attempt = 0; attempt < 20; attempt++)); do
        mutation_session_is_owned "$sid" "$token"
        state=$?
        [ "$state" -eq 1 ] && return 0
        if [ "$state" -eq 0 ]; then
            mutation_signal_session_groups "$sid" "$token" TERM
            signal_rc=$?
            [ "$signal_rc" -eq 1 ] && return 0
            [ "$signal_rc" -eq 0 ] || { sleep 0.05; continue; }
        fi
        sleep 0.05
    done
    # Re-scan and signal on every KILL attempt: a descendant may create a new
    # process group after any earlier snapshot. Repository checkers do not
    # daemonize into a different session.
    for ((attempt = 0; attempt < 100; attempt++)); do
        mutation_session_is_owned "$sid" "$token"
        state=$?
        [ "$state" -eq 1 ] && return 0
        if [ "$state" -eq 0 ]; then
            mutation_signal_session_groups "$sid" "$token" KILL
            signal_rc=$?
            [ "$signal_rc" -eq 1 ] && return 0
        fi
        sleep 0.05
    done
    return 1
}

mutation_bounded() {
    local slot ready_marker infra_marker checker_tmp child sid token token_suffix
    local registered_token rc monitor_mode=0 cleanup_rc=0
    mutation_timeout_is_valid "$MUTATION_TIMEOUT_S" || return 125
    [ ! -e "$MUTATION_STOP_FILE" ] || return 125
    slot=$(mktemp "$RESULT_DIR/checker-session.XXXXXX") || return 125
    token=${slot##*/}
    token_suffix=${token#checker-session.}
    ready_marker="$RESULT_DIR/checker-ready.$token_suffix"
    infra_marker="$RESULT_DIR/checker-infrastructure.$token_suffix"
    checker_tmp="$RESULT_DIR/checker-tmp.$token_suffix"
    mkdir "$checker_tmp" || { rm -f "$slot"; return 125; }

    case $- in *m*) monitor_mode=1; set +m ;; esac
    (
        printf '%s %s\n' "$BASHPID" "$token" > "$slot" || exit 125
        [ ! -e "$MUTATION_STOP_FILE" ] || exit 125
        export MUTATION_CHECKER_TOKEN="$token"
        export MUTATION_CHECKER_READY="$ready_marker"
        export MUTATION_INFRA_MARKER="$infra_marker"
        export MUTATION_CHECKER_TIMEOUT="$MUTATION_TIMEOUT_S"
        export MUTATION_CHECKER_TMP="$checker_tmp"
        exec setsid "$BASH" -c '
            : > "$MUTATION_CHECKER_READY" || exit 125
            exec timeout -k 10 "$MUTATION_CHECKER_TIMEOUT" env \
                GPSIM_TIMEOUT_SECONDS="$MUTATION_CHECKER_TIMEOUT" \
                TMPDIR="$MUTATION_CHECKER_TMP" "$@"
        ' mutation-checker "$@"
    ) &
    child=$!
    launching_checker_pid=$child
    # The child publishes independently, while this parent write closes the
    # normal launch gap. With monitor mode off, child PID == checker SID.
    printf '%s %s\n' "$child" "$token" > "$slot" || true
    [ "$monitor_mode" -eq 0 ] || set -m
    launching_checker_pid=0

    if wait "$child"; then rc=0; else rc=$?; fi
    [ -f "$ready_marker" ] || rc=125
    [ ! -f "$infra_marker" ] || rc=125
    read -r sid registered_token < "$slot"
    if [ "$registered_token" != "$token" ] \
            || ! mutation_terminate_checker_session "$sid" "$token"; then
        cleanup_rc=1
    fi
    [ ! -f "$infra_marker" ] || rc=125
    if [ "$cleanup_rc" -eq 0 ]; then
        rm -rf "$slot" "$ready_marker" "$infra_marker" "$checker_tmp"
    else
        return 125
    fi
    return "$rc"
}

# A PIC10F322 gpsim mutant is meaningful only after the unmutated image both
# builds successfully and passes the register-level check. In particular, never
# trust a HEX merely because it exists: a failed build can leave stale output.
PIC_GPSIM_OK=0
PIC_GPSIM_WHY="tools absent"
MUT_BASELINE_FAILED=0
probe_pic10f322_gpsim_baseline() {
    local root="$1" hex build_rc
    PIC_GPSIM_OK=0
    PIC_GPSIM_WHY="tools absent"

    # ci-local keeps STRICT_TOOLS=1 for every unskipped lane. Detect the shared
    # compiler/DFP inputs before Make so an explicitly authorized PIC omission
    # remains a genuine tools-absent skip rather than becoming a failed build.
    # Once the tools exist, any build failure is still a baseline failure.
    if ! mutation_command_is_available "$PIC12F675_MUTATION_CC" \
            || [ ! -f "$PIC12F675_MUTATION_DFP/pic/include/proc/pic10f322.h" ]; then
        echo "XC8/DFP absent -> PIC-shell mutants SKIPPED"
        return 1
    fi

    mutation_bounded "$MUTATION_MAKE" -C "$root" pic10f322 >/dev/null 2>&1
    build_rc=$?
    if [ "$build_rc" -ne 0 ]; then
        PIC_GPSIM_WHY="baseline FAILED"
        MUT_BASELINE_FAILED=1
        echo "PIC10F322 baseline build FAILED (status $build_rc) -> PIC-shell mutants SKIPPED"
        return 1
    fi

    hex="$root/$PIC10F322_MUTATION_HEX"
    if ! command -v "$GPSIM" >/dev/null 2>&1 || [ ! -f "$hex" ]; then
        echo "gpsim and/or XC8 absent -> PIC-shell mutants SKIPPED"
        return 1
    fi
    if ! mutation_bounded env GPSIM="$GPSIM" \
            "$PROJ_DIR/test/pic/run_gpsim_test.sh" "$hex" 0x3 >/dev/null 2>&1; then
        PIC_GPSIM_WHY="baseline FAILED"
        MUT_BASELINE_FAILED=1
        echo "PIC gpsim baseline FAILED -> PIC-shell mutants SKIPPED"
        return 1
    fi

    PIC_GPSIM_OK=1
    echo "gpsim + XC8 present, baseline PASS -> PIC gpsim mutants ENABLED"
}

mutation_command_is_available() {
    local command_name=$1
    [ -n "$command_name" ] || return 1
    case "$command_name" in
        */*) [ -x "$command_name" ] ;;
        *[[:space:]]*) return 1 ;;
        *) command -v "$command_name" >/dev/null 2>&1 ;;
    esac
}
mutation_command_for_sandbox() {
    local command_name=$1 path dir base resolved_dir
    case "$command_name" in
        /*) path=$command_name ;;
        */*) path="$PROJ_DIR/$command_name" ;;
        *) printf '%s\n' "$command_name"; return 0 ;;
    esac
    dir=${path%/*}
    base=${path##*/}
    if resolved_dir=$(cd "$dir" 2>/dev/null && pwd -P); then
        printf '%s/%s\n' "$resolved_dir" "$base"
    else
        printf '%s\n' "$path"
    fi
}
# Short soak window for the WDT-liveness mutant: must exceed one gpsim WDT period
# (~1.057s at WDTPS=0x08, per the soak's own note) so an un-pet dog actually
# fires, while staying quick. The baseline (pet) run sees zero resets and passes.
PIC_SOAK_MUT_MS="${PIC_SOAK_MUT_MS:-2500}"
# Liveness interval for that short window. The shared soak timing contract
# statically asserts SOAK_LIVENESS_INTERVAL_MS <= SOAK_DURATION_MS, so the
# Makefile default (60000 ms) will not compile against PIC_SOAK_MUT_MS. Keep it
# comfortably inside the window so the baseline (pet) run performs at least one
# real press/release round-trip instead of a vacuous zero-check pass. Must stay
# <= PIC_SOAK_MUT_MS.
PIC_SOAK_MUT_LIVENESS_MS="${PIC_SOAK_MUT_LIVENESS_MS:-1000}"

# --- Classic AVR (simavr) knobs -----------------------------------------------
# Short soak window for the Classic AVR WDT-liveness mutant. The ATtiny85 arms
# its watchdog at WDTO_250MS, so this is several periods: an un-pet dog resets
# well inside it while the baseline (pet) run stays quick. Simulated time, and
# simavr runs it far faster than real time. The liveness interval must stay
# <= the duration -- the shared soak timing contract static_asserts it -- and
# small enough that the baseline performs a real press/release round-trip
# instead of a vacuous zero-check pass.
AVR_SOAK_MUT_MS="${AVR_SOAK_MUT_MS:-2000}"
AVR_SOAK_MUT_LIVENESS_MS="${AVR_SOAK_MUT_LIVENESS_MS:-1000}"

# --- AVR-XT (ATtiny202) knobs -------------------------------------------------
# The two out-of-tree inputs the ATtiny202 lane needs, as ABSOLUTE paths. Both
# default to a path RELATIVE to the tree in the Makefile (XT_DFP,
# YASIMAVR_VENV), which is exactly wrong for a mktemp sandbox: `make -C "$work"`
# would resolve them under $work, find nothing, and every attiny202-* target
# would SKIP CLEANLY with status 0 -- scored as a survivor for every mutant in
# the lane. Passing them in absolutely keeps the sandbox self-contained for
# SOURCES while sharing the read-only toolchain, and the probe below refuses to
# enable the lane unless both actually resolve.
xt_dfp_input="${XT_DFP:-${XT_DFP_ABS:-third_party/attiny_dfp}}"
xt_yasimavr_venv_input="${YASIMAVR_VENV:-${XT_YASIMAVR_VENV_ABS:-third_party/yasimavr/venv}}"
case "$xt_dfp_input" in
    /*) xt_dfp_abs=$xt_dfp_input ;;
    *)  xt_dfp_abs="$PROJ_DIR/$xt_dfp_input" ;;
esac
case "$xt_yasimavr_venv_input" in
    /*) xt_yasimavr_venv_abs=$xt_yasimavr_venv_input ;;
    *)  xt_yasimavr_venv_abs="$PROJ_DIR/$xt_yasimavr_venv_input" ;;
esac
XT_MCU="${XT_MCU:-attiny202}"
XT_MUTATION_OBJDUMP=$(mutation_command_for_sandbox "${OBJDUMP:-avr-objdump}")
XT_MUTATION_NM=$(mutation_command_for_sandbox "${AVR_NM:-avr-nm}")
# sim_attiny202.py reads AVR_NM from the environment. Anchor path-qualified
# selections before Make enters a sandbox and preserve the command-name form for
# PATH lookup; AVR_NM is intentionally not a Make command-line override.
export AVR_NM="$XT_MUTATION_NM"
mutation_attiny202_tools_are_available() {
    local dfp=$1 venv=$2
    [ -f "$dfp/gcc/dev/$XT_MCU/device-specs/specs-$XT_MCU" ] \
        && [ -f "$dfp/gcc/dev/$XT_MCU/avrxmega3/short-calls/crt$XT_MCU.o" ] \
        && [ -f "$dfp/gcc/dev/$XT_MCU/avrxmega3/short-calls/lib$XT_MCU.a" ] \
        && [ -f "$dfp/include/avr/iotn202.h" ] \
        && [ -x "$venv/bin/python" ] \
        && "$venv/bin/python" -c \
            "from yasimavr.device_library import load_device; assert load_device('attiny202').find_peripheral('WDT') is not None" \
            >/dev/null 2>&1 \
        && mutation_command_is_available "$XT_MUTATION_OBJDUMP" \
        && mutation_command_is_available "$XT_MUTATION_NM"
}
# Soak window for the WDT-liveness mutant. The ATtiny202's fuse-locked WDT
# period is ~256 ms (WDTCFG=0x06), so this is many periods: an un-pet dog resets
# well inside it while the baseline (pet) run stays quick. Simulated time, and
# yasimavr runs it far faster than real time.
XT_SOAK_MUT_MS="${XT_SOAK_MUT_MS:-2000}"

# Parallelism. Every mutant runs in its own throwaway mktemp sandbox with its own
# build dirs (copy_tree + `make -C "$work"`), so mutants share nothing and can run
# concurrently. MUTATION_JOBS caps how many run at once; it defaults to the core
# count and is overridable (e.g. MUTATION_JOBS=4 to leave headroom, or =1 to force
# the old serial behaviour). Results are collected per-mutant into files and
# tallied deterministically after the pool drains, so the pass/fail verdict and
# the survivor list are identical to a serial run regardless of job count.
MUTATION_JOBS="${MUTATION_JOBS:-$(nproc 2>/dev/null || echo 4)}"
case "$MUTATION_JOBS" in
    ''|*[!0-9]*|0) echo "ERROR: MUTATION_JOBS must be a positive integer (got '$MUTATION_JOBS')" >&2; exit 2 ;;
esac

# Per-mutant result sink (one $idx.status + $idx.out file per mutant). Cleaned on
# exit so an interrupted run leaves nothing behind.
if ! RESULT_DIR="$(mktemp -d)"; then
    echo "ERROR: could not create mutation result directory" >&2
    exit 2
fi
result_dir_input=$RESULT_DIR
if ! RESULT_DIR=$(cd "$RESULT_DIR" && pwd -P); then
    rm -rf "$result_dir_input"
    echo "ERROR: could not resolve the mutation result directory" >&2
    exit 2
fi
MUTATION_STOP_FILE="$RESULT_DIR/stopping"
active_pids=()
launching_pid=0
launching_checker_pid=0
cleanup_mutation_run() {
    local original_status=$?
    local pid sid token expected_token slot attempt state signal age alive stable=0
    local process_pid process_pgid process_sid job_pgid runner_pgid
    local cleanup_failed=0
    local job_file="$RESULT_DIR/cleanup-jobs"
    local -a groups=() slots=() worker_slots=()
    local -A job_first_seen=()
    local -A session_first_seen=()
    local -A worker_first_seen=()
    local -A worker_slot_by_token=()
    local -A worker_signal_by_token=()
    local -A checker_sid_by_token=()
    local -A checker_signal_by_token=()
    local -A signalled_groups=()
    trap - EXIT
    trap '' HUP INT TERM
    : > "$MUTATION_STOP_FILE" 2>/dev/null || true
    if mutation_snapshot_processes; then
        while read -r process_pid process_pgid process_sid; do
            [ "$process_pid" = "$BASHPID" ] && { runner_pgid=$process_pgid; break; }
        done <<< "$MUTATION_PROCESS_SNAPSHOT"
    fi
    if [ -z "${runner_pgid:-}" ]; then
        cleanup_failed=1
        runner_pgid=-1
    fi

    # Discover jobs in this shell, not a process-substitution subshell (which has
    # no Bash job table). Re-scan both jobs and registration slots throughout the
    # grace period to close worker and checker launch windows. Numeric IDs are
    # signalled only while the shell still owns the job or the session still
    # carries its private token, so a completed ID cannot hit an unrelated reuse.
    for ((attempt = 0; attempt < 120; attempt++)); do
        alive=0
        if jobs -p > "$job_file" 2>/dev/null; then
            mapfile -t groups < "$job_file"
        else
            groups=()
            alive=1
            cleanup_failed=1
        fi

        worker_slot_by_token=()
        worker_signal_by_token=()
        checker_sid_by_token=()
        checker_signal_by_token=()
        signalled_groups=()
        shopt -s nullglob globstar
        worker_slots=("$RESULT_DIR"/**/mutation-worker.*)
        slots=("$RESULT_DIR"/**/checker-session.*)
        shopt -u nullglob globstar
        for slot in "${worker_slots[@]}"; do
            [ -s "$slot" ] || { alive=1; continue; }
            read -r pid token < "$slot" || { alive=1; continue; }
            expected_token=${slot##*/}
            [[ $pid =~ ^[1-9][0-9]*$ && $token = "$expected_token" ]] \
                || continue
            if [[ -z ${worker_first_seen["$slot"]+x} ]]; then
                worker_first_seen["$slot"]=$attempt
            fi
            age=$((attempt - worker_first_seen["$slot"]))
            if [ "$age" -lt 20 ]; then signal=TERM; else signal=KILL; fi
            worker_slot_by_token["$token"]=$slot
            worker_signal_by_token["$token"]=$signal
        done
        for slot in "${slots[@]}"; do
            [ -s "$slot" ] || { alive=1; continue; }
            read -r sid token < "$slot" || { alive=1; continue; }
            expected_token=${slot##*/}
            [[ $sid =~ ^[1-9][0-9]*$ && $token = "$expected_token" ]] \
                || continue
            if [[ -z ${session_first_seen["$slot"]+x} ]]; then
                session_first_seen["$slot"]=$attempt
            fi
            age=$((attempt - session_first_seen["$slot"]))
            if [ "$age" -lt 20 ]; then signal=TERM; else signal=KILL; fi
            checker_sid_by_token["$token"]=$sid
            checker_signal_by_token["$token"]=$signal
        done

        if ! mutation_snapshot_processes; then
            alive=1
            cleanup_failed=1
            sleep 0.05
            continue
        fi
        for pid in "${groups[@]}"; do
            [ -n "$pid" ] || continue
            if [[ -z ${job_first_seen["$pid"]+x} ]]; then
                job_first_seen["$pid"]=$attempt
            fi
            age=$((attempt - job_first_seen["$pid"]))
            if [ "$age" -lt 20 ]; then signal=TERM; else signal=KILL; fi
            job_pgid=
            while read -r process_pid process_pgid process_sid; do
                [ "$process_pid" = "$pid" ] \
                    && { job_pgid=$process_pgid; break; }
            done <<< "$MUTATION_PROCESS_SNAPSHOT"
            if [ -n "$job_pgid" ] && [ "$job_pgid" != "$runner_pgid" ]; then
                kill -"$signal" -- "-$job_pgid" 2>/dev/null || true
            elif [ -n "$job_pgid" ]; then
                kill -"$signal" "$pid" 2>/dev/null || true
            fi
            alive=1
        done

        while read -r process_pid process_pgid process_sid; do
            mutation_process_read_ownership_tokens "$process_pid" || continue
            token=$MUTATION_PROCESS_WORKER_TOKEN
            if [ -n "$token" ] && [[ -n ${worker_slot_by_token["$token"]+x} ]]; then
                signal=${worker_signal_by_token["$token"]}
                if [[ -z ${signalled_groups["$signal:$process_pgid"]+x} ]]; then
                    signalled_groups["$signal:$process_pgid"]=1
                    kill -"$signal" -- "-$process_pgid" 2>/dev/null || true
                fi
                alive=1
            fi
            token=$MUTATION_PROCESS_CHECKER_TOKEN
            if [ -n "$token" ] && [[ -n ${checker_sid_by_token["$token"]+x} ]] \
                    && [ "$process_sid" = "${checker_sid_by_token["$token"]}" ]; then
                signal=${checker_signal_by_token["$token"]}
                if [[ -z ${signalled_groups["$signal:$process_pgid"]+x} ]]; then
                    signalled_groups["$signal:$process_pgid"]=1
                    kill -"$signal" -- "-$process_pgid" 2>/dev/null || true
                fi
                alive=1
            fi
        done <<< "$MUTATION_PROCESS_SNAPSHOT"

        if [ "$alive" -eq 0 ]; then stable=$((stable + 1)); else stable=0; fi
        [ "$stable" -ge 5 ] && break
        sleep 0.05
    done
    for pid in "${active_pids[@]}" "$launching_pid" "$launching_checker_pid"; do
        [ "$pid" -eq 0 ] || wait "$pid" 2>/dev/null || true
    done
    if [ "$attempt" -ge 120 ]; then
        cleanup_failed=1
        echo "ERROR: mutation cleanup could not prove all owned processes exited" >&2
    fi
    if [ "$cleanup_failed" -eq 0 ]; then
        rm -rf "$RESULT_DIR"
    else
        echo "ERROR: retaining mutation run root for failed cleanup: $RESULT_DIR" >&2
        [ "$original_status" -ne 0 ] || original_status=2
    fi
    exit "$original_status"
}
mutation_signal_exit() {
    local code=$1
    trap '' HUP INT TERM
    exit "$code"
}
trap cleanup_mutation_run EXIT
trap 'mutation_signal_exit 129' HUP
trap 'mutation_signal_exit 130' INT
trap 'mutation_signal_exit 143' TERM

# Bounded-concurrency dispatch. Keep every PID so every worker status is checked;
# an unchecked `wait -n` can lose a worker that died after publishing half a
# result and let its stale status be credited as a kill.
dispatched=0
worker_failures=0
wait_oldest_worker() {
    local pid=${active_pids[0]}
    if ! wait "$pid"; then worker_failures=$((worker_failures + 1)); fi
    active_pids=("${active_pids[@]:1}")
}
dispatch() {
    local worker_slot worker_token worker_rc
    worker_slot=$(mktemp "$RESULT_DIR/mutation-worker.XXXXXX") || {
        echo "ERROR: could not create mutation worker registration" >&2
        exit 2
    }
    worker_token=${worker_slot##*/}
    printf '0 %s\n' "$worker_token" > "$worker_slot" || {
        rm -f "$worker_slot"
        echo "ERROR: could not initialize mutation worker registration" >&2
        exit 2
    }
    # Briefly enable job control so this worker and every descendant Make process
    # receive their own process group. Disable it before waiting to suppress job
    # notifications in the deterministic mutation log.
    set -m
    (
        export MUTATION_WORKER_TOKEN="$worker_token"
        printf '%s %s\n' "$BASHPID" "$worker_token" > "$worker_slot" || exit 125
        [ ! -e "$MUTATION_STOP_FILE" ] || exit 125
        if run_mutant "$@"; then worker_rc=0; else worker_rc=$?; fi
        rm -f "$worker_slot"
        exit "$worker_rc"
    ) &
    launching_pid=$!
    set +m
    active_pids+=("$launching_pid")
    launching_pid=0
    dispatched=$((dispatched + 1))
    if [ "${#active_pids[@]}" -ge "$MUTATION_JOBS" ]; then
        wait_oldest_worker
    fi
}
drain_workers() {
    while [ "${#active_pids[@]}" -ne 0 ]; do wait_oldest_worker; done
}

# Each entry: file<TAB>sed-expression<TAB>make-target<TAB>description
# The sed expression uses '@' as delimiter to avoid clashing with C operators.
MUTATIONS=(
"src/bypass_mcu_avr_classic.c	s@hw_outputs_reassert_safe();@@	test-fault-inject-tq2_l2_5v_relay-attiny85	fail-safe coil de-energization removed from hw_force_wdt_reset(); inject_coil_resync sees the injected coil latch still driven when the escalation path spins"
# --- core debounce algorithm (bypass_pure.c) -----------------------------------
"src/bypass_pure.c	s@{ ++counter; }@{ --counter; }@	test-sim-cd4053_simple-attiny13a	ISR integrator: increment-on-press becomes decrement (counter never rises -> never toggles)"
"src/bypass_pure.c	s@ctx.debounce_counter >= PRESSED_THRESH@ctx.debounce_counter > PRESSED_THRESH@	test-sim-cd4053_simple-attiny13a	press threshold off-by-one (>= becomes >); test_minimum_press_toggles catches the 1-tick divergence"
"src/bypass_mcu_avr_classic.c	s@PORTB |=  (1 << LED_PIN)@PORTB \&= (uint8_t)~(1 << LED_PIN)@	test-sim-cd4053_simple-attiny13a	set_engaged LED output inverted (lights become dark)"
"src/bypass_config.h	s@#define PRESSED_THRESH (8U)@#define PRESSED_THRESH (4U)@	test-sim-cd4053_simple-attiny13a	press threshold shortened 8->4 (timing/noise-count regression)"
"src/bypass_config.h	s@#define RELEASE_THRESH (25U)@#define RELEASE_THRESH (15U)@	test-sim-cd4053_simple-attiny13a	release lock-out shortened 25->15 (noise-count regression)"
# --- ISR bounds guards (bypass_pure.c) -----------------------------------------
"src/bypass_pure.c	s@if (debounce_counter < RELEASE_THRESH) { ++counter; }@++counter;@	test-sim-cd4053_simple-attiny13a	ISR increment: remove saturation guard (counter wraps from 255->0 after 256 sustained ticks)"
"src/bypass_pure.c	s@if (debounce_counter > 0U) { --counter; }@--counter;@	test-sim-cd4053_simple-attiny13a	ISR decrement: remove underflow guard (counter wraps 0->255 on release; lock-step catches divergence)"
# --- power-on initialization (bypass_pure.c) ------------------------------------
# simavr cannot reliably inject a held switch at power-on (PORTB write in init()
# resets the IRQ-driven pin level), so these map to test-model-check which calls
# debounce_init_context() directly and checks both return fields.
"src/bypass_pure.c	s@ctx.program_state = RELEASE_DEBOUNCE_WAIT;@ctx.program_state = PRESS_DEBOUNCE_WAIT;@	test-model-check	power-on-pressed: wrong program_state; verify_init_context() checks RELEASE_DEBOUNCE_WAIT"
"src/bypass_pure.c	s@ctx.debounce_counter = RELEASE_THRESH;@ctx.debounce_counter = 0U;@	test-model-check	power-on-pressed: lockout counter 0 instead of RELEASE_THRESH; verify_init_context() checks counter"
# --- lockout mechanism (bypass_pure.c) -----------------------------------------
"src/bypass_pure.c	s@res.lockout_value = RELEASE_THRESH;@res.lockout_value = 0;@g	test-sim-cd4053_simple-attiny13a	toggle lockout: counter reset to 0 instead of RELEASE_THRESH (immediate re-arm, no hold lockout)"
"src/bypass_pure.c	s@res.program_state = RELEASE_DEBOUNCE_WAIT;@res.program_state = PRESS_DEBOUNCE_WAIT;@g	test-sim-cd4053_simple-attiny13a	toggle lockout: stays in PRESS_DEBOUNCE_WAIT after toggle (counter=25 >= 8 -> immediate re-toggle cascade)"
# --- watchdog handshake (bypass_mcu_avr_classic.c) ----------------------------------------
# Note what kills each of these, because it is NOT the watchdog on the first
# two. `test-sim-cd4053_simple-attiny13a` is the ATtiny13a build, and simavr 1.6 does not model
# the ATtiny13a WDT system reset at all (see test_sim.c's
# test_watchdog_backstop_documented) -- so no assertion on that lane can observe
# a watchdog reset. The third entry is the one that actually exercises the
# watchdog: it runs on the tinyx5, where simavr does model the reset, and is
# killed by the soak's reset witness.
"src/bypass_mcu_avr_classic.c	s@hw_wdt_pet();@(void)0; /* MUTANT: no WDT pet */@	test-sim-cd4053_simple-attiny13a	WDT pet call site removed from the main loop: it is the only caller, so hw_wdt_pet goes unused and the build fails under -Werror=unused-function before any test runs. Kept because that compiler guard is real coverage; the BEHAVIOURAL form of this fault is the soak mutant below"
"src/bypass_mcu_avr_classic.c	s@timer_isr_called_ = TIMER_ISR_CALLED;@timer_isr_called_ = TIMER_ISR_NOT_CALLED;@	test-sim-cd4053_simple-attiny13a	WDT handshake: ISR clears its own flag -> main never sees CALLED -> the debounce state machine never advances, so the LED never toggles; the functional, noise-count and lock-step assertions all fail (the ATtiny13a watchdog is not what catches it)"
"src/bypass_mcu_avr_classic.c	s@static void hw_wdt_pet(void) { wdt_reset(); }@static void hw_wdt_pet(void) { /* MUTANT: no WDT pet */ }@	AVR_SOAK_VARIANT=cd4053_simple AVR_SOAK_CHIP=attiny85 AVR_SOAK_DURATION_MS=$AVR_SOAK_MUT_MS AVR_SOAK_LIVENESS_INTERVAL_MS=$AVR_SOAK_MUT_LIVENESS_MS test-soak	SOAK main-loop WDT pet defeated at the definition, so the call site remains and the build stays clean; the tinyx5 soak's reset witness records the un-pet watchdog in watchdog_failures within the short mutation window"
# --- main-loop sanity guard / toggle dispatch (bypass_mcu_avr_classic.c) -------------------
"src/bypass_mcu_avr_classic.c	s@(actual_direction_mask == (uint8_t)BYPASS_OUTPUT_DDR_MASK)@(1U != 0U)@	test-sim-cd4053_simple-attiny13a	DDRB exact-mask predicate removed: PB0 output and PB4 input corruptions evade the former caller-output subset check"
"src/bypass_mcu_avr_classic.c	s@PORTB & (uint8_t)BYPASS_OUTPUT_DDR_MASK@PORTB \& (uint8_t)0x0EU@	test-sim-cd4053_simple-attiny13a	output-latch mask omits spare PB4; PB4 corruption must still force watchdog recovery"
"src/bypass_mcu_avr_classic.c	s@(timer_isr_called_ > TIMER_ISR_NOT_CALLED)@(0U != 0U)@	test-fault-inject-cd4053_simple-attiny85	invalid ISR/main handshake-value guard removed; ISR-write-synchronized corruption must still force and witness a WDT reset"
"src/bypass_pure.c	s@res.effect_state = BYPASS;@res.effect_state = ENGAGED;@	test-sim-cd4053_simple-attiny13a	toggle: always sets ENGAGED (never returns to BYPASS); round-trip and lock-step tests catch it"
# --- CD4053 simple output driver -----------------------------------------------
"src/bypass_output_cd4053_simple.c	s@hw_pin_set_low(CD4053_PIN)@hw_pin_set_high(CD4053_PIN)@	test-sim-cd4053_simple-attiny13a	bypass routes CD4053 the wrong way (PB2 stuck high); power-on control-output test catches it"
"src/bypass_output_cd4053_simple.c	s@hw_pin_set_high(CD4053_PIN)@hw_pin_set_low(CD4053_PIN)@	test-sim-cd4053_simple-attiny13a	engaged routes CD4053 the wrong way (PB2 stuck low); control-output test catches it"
# --- TQ2 relay output driver ---------------------------------------------------
"src/bypass_mcu_pic12f675.c	/void hw_pin_mask_set_low/,/^}/s@gpio_shadow_ &= (uint8_t)~pin_mask;@(void)pin_mask;\n    gpio_shadow_ \&= (uint8_t)~(1U << RELAY_RESET_PIN);\n    GPIO = gpio_shadow_;\n    gpio_shadow_ \&= (uint8_t)~(1U << RELAY_SET_PIN);@	host:atomic-clear|pic12f675-coverage-check-fw	PIC12F675 relay masked clear restored to sequential whole-port writes; RESET/SET/both shadow cases require both coil bits clear before one GPIO write with no intermediate modeled-GPIO high"
"src/bypass_mcu_pic12f675.c	/static void hw_emergency_outputs_quiesce/,/^}/s@    gpio_shadow_ &= (uint8_t)~(uint8_t)(1U << SPARE_OUTPUT_PIN);@@	host:parked-output|pic12f675-coverage-check-fw	PIC12F675 relay emergency canonicalization drops parked GP4 and clears only the coils; the escalation's one whole-port write then publishes a corrupt GP4 intent bit to the pad. Reset entry and both coil assertions stay green, so only the pre-spin physical-pin observation kills it"
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	test-sim-tq2_l2_5v_relay-attiny13a	relay coil pulse shortened to 1ms (< 4ms datasheet min); pulse-width test catches it"
"src/bypass_output_tq2_l2_5v_relay.c	s@pin_set_high(RELAY_SET_PIN)@pin_set_high(RELAY_RESET_PIN)@	test-sim-tq2_l2_5v_relay-attiny13a	engage pulses the wrong (RESET) coil; relay test catches SET-not-pulsed / RESET-moved"
# --- CD4053 with-mute output driver --------------------------------------------
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	test-sim-cd4053_with_mute-attiny13a	mute settle window shortened to 1ms; mute-window timing test catches it"

# --- shared core: migrated from the PIC10F320 project (merge, 2026-07-26) ------
# Its other five model mutants duplicate entries already above; this one does
# not. It is the oracle for verify_corrupt_state_faults(), the property Phase 3
# moved into test/formal/test_model_check.c, and it is retargeted from the dead
# vendored copy to the single verified core.
"src/bypass_pure.c	s@res.fault = true;@res.fault = false;@	test-model-check	MODEL corrupt-state fault suppressed (verify_corrupt_state_faults catches it)"
# --- F2 context-SEU detection (BYPASS_CTX_CHECK) ------------------------------
# Transaction-seam mutants for the complemented XOR-fold context check. The
# post-check probes must reject any shell that resumes from a validated local
# snapshot but then consumes or re-folds live persisted SRAM. PIC10F320 is
# F2-EXCLUDED (asserted after the inventory build).
"src/bypass_mcu_avr_classic.c	s@                ctx_check_ = debounce_ctx_check_word(next_ctx);@                (void)0; /* MUTANT: main-loop transaction check dropped */@	test-sim-cd4053_simple-attiny13a	F2 main-loop transaction publication dropped. The shadow goes stale on the first state change, so the next ISR rejects the pair and the functional round trip cannot complete."
"src/bypass_mcu_avr_classic.c	s@                next_ctx.debounce_counter);@                ctx_.debounce_counter); /* MUTANT: consume live persisted SRAM */@	test-fault-inject-cd4053_simple-attiny85	F2 ISR transaction defeated after validation: integration consumes live ctx_ instead of the validated snapshot. The one-shot post-check injection is then applied and folded into a phantom transition."
"src/bypass_pure.c	s@                ^ ctx.debounce_counter))@                ))@	test-fault-inject-tq2_l2_5v_relay-attiny85	F2 fold weakened: the complemented XOR-fold drops the debounce_counter term, so the shadow no longer covers the counter and an in-range counter SEU is invisible to it. The fault-inject in-range case sees no WDT reset -- proves the fold actually covers the counter."
"src/bypass_mcu_pic10f322.c	s@        ctx_check_ = debounce_ctx_check_word(next_ctx);@        ctx_check_ = debounce_ctx_check_word(ctx_); /* MUTANT: re-fold live persisted SRAM */@	pic10f322-coverage-check-fw	PIC10F322 F2 transaction defeated after validation: publication re-folds live ctx_ rather than the intended successor. The host one-shot post-check injection proves the upset cannot be legitimized."
"src/bypass_mcu_pic12f675.c	s@        ctx_check_ = debounce_ctx_check_word(next_ctx);@        ctx_check_ = debounce_ctx_check_word(ctx_); /* MUTANT: re-fold live persisted SRAM */@	pic12f675-coverage-check-fw	PIC12F675 F2 transaction defeated after validation: publication re-folds live ctx_ rather than the intended successor. The host one-shot post-check injection proves the upset cannot be legitimized."
)

# Files copied into each sandbox: all firmware sources + headers, the Makefile,
# scripts/, and every source file under test/ at any depth. The walk itself, and
# the rationale for every part of it, lives in test/scratch_tree.sh so that this
# runner and test/test_pic_rebuild.sh cannot drift apart again. This binds it to
# the real tree; the name stays because the sandbox self-tests, the survivor
# diagnostics and the merge-plan record all speak of copy_tree.
copy_tree() {
    scratch_tree_copy "$PROJ_DIR" "$1"
}

# Fail CLOSED on an incomplete sandbox. Every entry here is a file whose absence
# does not announce itself: the sandbox still builds, the baseline still runs,
# and the probe records a plain FAIL that the summary reports as a skip -- so the
# gate silently shrinks instead of breaking. find_pin_exact.h is on this list
# because that is precisely what it did (see test/scratch_tree.sh), and it is
# worth being blunt about why the list did not save us: it is hand-maintained, so
# it protects only against gaps someone already thought of. The allowlist walk in
# test/scratch_tree.sh is the real fix; this is the check that turns a future
# omission into one obvious line instead of a misattributed toolchain complaint.
validate_pic10f320_sandbox() {
    local root="$1" required ok=1
    for required in \
        test/pic/footswitch_toggle.stc \
        test/pic/power_on_pressed.stc \
        test/pic/find_pin_exact.h \
        test/pic/gpsim_bootstrap.h \
        test/pic/soak_sampling.h \
        test/pic/gpsim_wrapper_common.sh \
        test/pic/test_fault_pic_core.h \
        test/pic/test_io_pic_core.h \
        test/pic/test_lockstep_pic_core.h \
		test/pic/target_result.h \
        test/pic/test_soak_pic.cc; do
        if [ ! -f "$root/$required" ]; then
            echo "ERROR: PIC10F320 mutation sandbox is missing $required" >&2
            ok=0
        fi
    done
    for required in \
        test/pic/run_gpsim_test.sh \
        test/pic/run_gpsim_power_on_pressed.sh; do
        if [ ! -x "$root/$required" ]; then
            echo "ERROR: PIC10F320 mutation sandbox helper is missing or not executable: $required" >&2
            ok=0
        fi
    done
    [ "$ok" -eq 1 ]
}

# The PIC12F675 counterpart. Same failure mode, one extra hazard: this part is
# the only one whose simulator images are DERIVED, so pic12f675-simcal must find
# both python3 and the injector. A sandbox missing the injector does not build a
# broken image -- it builds no derived image at all, every lane below skips with
# status 0, and the baseline probe reports the whole part as "tools absent" on a
# host that has every tool.
validate_pic12f675_sandbox() {
    local root="$1" required ok=1
    for required in \
        test/pic/inject_calibration_word.py \
        test/pic/pic12f675_matrix_evidence.py \
        test/pic/pic12f675_footswitch_toggle.stc \
        test/pic/pic12f675_power_on_pressed.stc \
        test/pic/pic12f675_gpsim_regs.sh \
        test/pic/pic12f675_regs.h \
        test/pic/pic12f675_fault_matrix.h \
        test/pic/test_io_pic12f675.cc \
        test/pic/test_lockstep_pic12f675.cc \
        test/pic/test_fault_pic12f675.cc \
		test/pic/target_result.h \
		test/pic/test_target_result_records.cc \
        test/pic/test_soak_pic12f675.cc \
        test/pic/test_soak_pic_core.h; do
        if [ ! -f "$root/$required" ]; then
            echo "ERROR: PIC12F675 mutation sandbox is missing $required" >&2
            ok=0
        fi
    done
    [ "$ok" -eq 1 ]
}

# The AVR-XT counterpart, and for the same reason: every attiny202-* target
# skips cleanly on a missing input, so a file that copy_tree failed to bring
# across turns the whole lane into silent survivors rather than a loud error.
# The Python drivers and the golden-model bridge are the pieces that would go
# missing without announcing it -- the sandbox still builds an image, and the
# harness still "runs".
validate_avr_xt_sandbox() {
    local root="$1" required ok=1
    for required in \
        test/avr/sim_attiny202.py \
        test/avr/attiny202_fuses.py \
        test/avr/test_sim_attiny202.py \
        test/avr/test_fault_attiny202.py \
        test/avr/test_soak_attiny202.py \
        test/avr/test_lockstep_attiny202.py \
        test/avr/test_attiny202_delay_oracle.py \
        test/avr/model_step_ffi.c \
        test/avr/model_step_ffi.py \
        test/model_step.h; do
        if [ ! -f "$root/$required" ]; then
            echo "ERROR: AVR-XT mutation sandbox is missing $required" >&2
            ok=0
        fi
    done
    [ "$ok" -eq 1 ]
}

SANDBOX_SELFTEST_DONE=0
if [ "${MUTATION_SANDBOX_SELFTEST:-0}" = 1 ]; then
    if ! SELFTEST_DIR="$(mktemp -d "$RESULT_DIR/selftest.XXXXXX")"; then
        echo "ERROR: could not create mutation self-test sandbox" >&2
        exit 1
    fi
    if ! copy_tree "$SELFTEST_DIR" || ! validate_pic10f320_sandbox "$SELFTEST_DIR" \
            || ! validate_pic12f675_sandbox "$SELFTEST_DIR"; then
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    # Aggregate consumers now require the retained-matrix hash oracle just as
    # simulator-image production requires the calibration injector.
    rm -f "$SELFTEST_DIR/test/pic/pic12f675_matrix_evidence.py"
    if validate_pic12f675_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a missing matrix evidence oracle" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi
    if ! copy_tree "$SELFTEST_DIR"; then
        echo "ERROR: could not restore mutation self-test sandbox" >&2
        rm -rf "$SELFTEST_DIR"; exit 1
    fi

    # The PIC12F675 hazard specifically: without the injector no derived image
    # exists, so every lane skips clean and the probe blames the toolchain.
    rm -f "$SELFTEST_DIR/test/pic/inject_calibration_word.py"
    if validate_pic12f675_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a missing calibration injector" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    if ! copy_tree "$SELFTEST_DIR"; then
        echo "ERROR: could not restore mutation self-test sandbox" >&2
        rm -rf "$SELFTEST_DIR"; exit 1
    fi

    rm -f "$SELFTEST_DIR/test/pic/run_gpsim_test.sh"
    if validate_pic10f320_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a missing gpsim wrapper" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    if ! copy_tree "$SELFTEST_DIR"; then
        echo "ERROR: could not restore mutation self-test sandbox" >&2
        rm -rf "$SELFTEST_DIR"; exit 1
    fi
    chmod -x "$SELFTEST_DIR/test/pic/run_gpsim_power_on_pressed.sh"
    if validate_pic10f320_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a non-executable gpsim wrapper" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    if ! copy_tree "$SELFTEST_DIR"; then
        echo "ERROR: could not restore mutation self-test sandbox" >&2
        rm -rf "$SELFTEST_DIR"; exit 1
    fi
    rm -f "$SELFTEST_DIR/test/pic/find_pin_exact.h"
    if validate_pic10f320_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a missing find_pin_exact.h" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    if ! copy_tree "$SELFTEST_DIR"; then
        echo "ERROR: could not restore mutation self-test sandbox" >&2
        rm -rf "$SELFTEST_DIR"; exit 1
    fi
    rm -f "$SELFTEST_DIR/test/pic/test_fault_pic_core.h"
    if validate_pic10f320_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a missing shared PIC harness core" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    # Depth regression, and the one check that would have caught the original
    # defect. Everything above passes against a single-level copy: the files it
    # asserts all sit at test/pic/. These two do not -- find_pin_exact.h needs a
    # walk that takes headers from a subdirectory, fw_coverage_harness.h needs
    # one that descends three levels -- so a copy_tree that regresses on either
    # axis fails here rather than in a baseline, ten minutes later, wearing a
    # "toolchain absent" label.
    if ! copy_tree "$SELFTEST_DIR"; then
        echo "ERROR: could not restore mutation self-test sandbox" >&2
        rm -rf "$SELFTEST_DIR"; exit 1
    fi
    for required in test/pic/find_pin_exact.h \
                    test/pic/fw_coverage/fw_coverage_harness.h; do
        if [ ! -f "$SELFTEST_DIR/$required" ]; then
            echo "ERROR: mutation sandbox copy did not reach $required" >&2
            rm -rf "$SELFTEST_DIR"
            exit 1
        fi
    done

    # Same discipline for the AVR-XT lane. model_step.h sits at test/ root while
    # its bridge sits at test/avr/, so this also re-checks that the walk takes
    # BOTH levels -- and .c alongside .py, since the golden-model bridge is one
    # of each and a lane missing either silently degrades to survivors.
    copy_tree "$SELFTEST_DIR"
    if ! validate_avr_xt_sandbox "$SELFTEST_DIR"; then
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    rm -f "$SELFTEST_DIR/test/avr/model_step_ffi.py"
    if validate_avr_xt_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a missing AVR-XT model bridge" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    rm -rf "$SELFTEST_DIR"
    SANDBOX_SELFTEST_DONE=1
fi

# Run one PIC gpsim register-level check against a freshly built (mutated) HEX.
# We build + drive the wrapper DIRECTLY rather than via `make pic10f322-test-gpsim`.
# That began as a workaround: the target's preflight checked its wrapper scripts'
# mode in the git index, which no mktemp sandbox can satisfy. The workaround was
# applied HERE and nowhere else, so the PIC10F320 lane -- which does go through
# Make -- kept failing its baseline for a reason nobody could see from the
# summary. The preflight now skips the index check outside a work tree, so both
# routes work and this one is a deliberate choice rather than a dodge: it is one
# process instead of a Make invocation per mutant, and it is the same call the
# 322 probe makes, so probe and mutant cannot diverge.
#
# The cd4053 variant with its full ENGAGED LATA (0x3) exercises the LED (RA0),
# the footswitch read (RA3) and a control pin (RA1) in one run -- enough to kill
# every PIC gpsim mutant below. Returns nonzero (killed) on a build break or a
# failed gpsim assertion.
pic_gpsim_run() {
    local work="$1" rc
    mutation_bounded "$MUTATION_MAKE" -C "$work" pic10f322 >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    local hex="$work/$PIC10F322_MUTATION_HEX"
    [ -f "$hex" ] || return 125
    # `env` rather than a GPSIM= prefix on mutation_bounded: a var-prefix on a
    # SHELL FUNCTION is scoped differently in bash than on an external command
    # (it can persist in the caller), so pass it to the timed command explicitly.
    mutation_bounded env GPSIM="$GPSIM" \
        "$PROJ_DIR/test/pic/run_gpsim_test.sh" "$hex" 0x3 >/dev/null 2>&1
}

split_mutation_make_command() {
    local label=$1 command=$2 i last
    MUTATION_MAKE_ARGS=()
    read -r -a MUTATION_MAKE_ARGS <<< "$command"
    if [ "${#MUTATION_MAKE_ARGS[@]}" -eq 0 ]; then
        echo "ERROR: mutation make command $label is empty" >&2
        return 1
    fi
    last=$((${#MUTATION_MAKE_ARGS[@]} - 1))
    for ((i = 0; i < last; i++)); do
        if ! [[ ${MUTATION_MAKE_ARGS[i]} =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+$ ]]; then
            echo "ERROR: mutation make command $label has an invalid assignment" >&2
            return 1
        fi
    done
    if ! [[ ${MUTATION_MAKE_ARGS[last]} =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "ERROR: mutation make command $label has an invalid target" >&2
        return 1
    fi
}

run_mutation_make_command() {
    local root=$1 command=$2
    shift 2
    split_mutation_make_command runtime "$command" || return 2
    mutation_bounded "$MUTATION_MAKE" -C "$root" "$@" "${MUTATION_MAKE_ARGS[@]}"
}

# PIC12F675 mutants need positive evidence that the named oracle observed the
# intended behavior. A bare nonzero Make status is not enough: XC8 rejecting the
# mutated source, a host-harness compile failure, or an incomplete simulator run
# all fail too, and none demonstrates that the firmware fault was detected.
mutation_command_assignment() {
    local command=$1 wanted=$2 i last
    MUTATION_COMMAND_ASSIGNMENT=
    split_mutation_make_command assignment "$command" || return 1
    last=$((${#MUTATION_MAKE_ARGS[@]} - 1))
    for ((i = 0; i < last; i++)); do
        case "${MUTATION_MAKE_ARGS[i]}" in
            "$wanted="*)
                [ -z "$MUTATION_COMMAND_ASSIGNMENT" ] || return 1
                MUTATION_COMMAND_ASSIGNMENT=${MUTATION_MAKE_ARGS[i]#*=}
                ;;
        esac
    done
    [ -n "$MUTATION_COMMAND_ASSIGNMENT" ]
}

pic12f675_gpsim_results_complete() {
    local mode=$1 log=$2 line path variant status pass_count=0 fail_count=0
    local -a results=()
    local -A variant_count=()
    mapfile -t results < <(grep '^RESULT: ' "$log" || true)
    [ "${#results[@]}" -eq 6 ] || return 1
    for line in "${results[@]}"; do
        if [[ $line =~ ^RESULT:\ PASS\ \((.*)\)$ ]]; then
            status=pass; path=${BASH_REMATCH[1]}; pass_count=$((pass_count + 1))
        elif [[ $line =~ ^RESULT:\ ([1-9][0-9]*)\ check\(s\)\ FAILED\ for\ (.*)$ ]]; then
            status=fail; path=${BASH_REMATCH[2]}; fail_count=$((fail_count + 1))
        else
            return 1
        fi
        case "${path##*/}" in
            bypass-pic12f675-cd4053_simple_simcal.hex) variant=cd4053_simple ;;
            bypass-pic12f675-cd4053_with_mute_simcal.hex) variant=cd4053_with_mute ;;
            bypass-pic12f675-tq2_l2_5v_relay_simcal.hex) variant=tq2_l2_5v_relay ;;
            *) return 1 ;;
        esac
        variant_count["$variant"]=$((${variant_count["$variant"]:-0} + 1))
    done
    for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
        [ "${variant_count["$variant"]:-0}" -eq 2 ] || return 1
    done
    case "$mode" in
        pass) [ "$pass_count" -eq 6 ] && [ "$fail_count" -eq 0 ] ;;
        fail) [ "$fail_count" -gt 0 ] ;;
        *) return 2 ;;
    esac
}

pic12f675_soak_result_complete() {
    local mode=$1 command=$2 log=$3 line variant requested_duration
    local liveness combination status duration checks failures watchdog liveness_failures
    local -a records=()
    mutation_command_assignment "$command" PIC12F675_SOAK_VARIANT || return 1
    variant=$MUTATION_COMMAND_ASSIGNMENT
    mutation_command_assignment "$command" PIC12F675_SOAK_DURATION_MS || return 1
    requested_duration=$MUTATION_COMMAND_ASSIGNMENT
    mutation_command_assignment "$command" PIC12F675_SOAK_LIVENESS_INTERVAL_MS || return 1
    liveness=$MUTATION_COMMAND_ASSIGNMENT
    mutation_command_assignment "$command" PIC12F675_SOAK_COMBINATION_NAME || return 1
    combination=$MUTATION_COMMAND_ASSIGNMENT
    [ "$variant" = cd4053_simple ] \
        && [[ $requested_duration =~ ^[1-9][0-9]*$ ]] \
        && [[ $liveness =~ ^[1-9][0-9]*$ ]] || return 1
    mapfile -t records < <(grep '^SOAK_RESULT ' "$log" || true)
    [ "${#records[@]}" -eq 1 ] || return 1
    line=${records[0]}
    if [[ $line =~ ^SOAK_RESULT\ format=1\ status=(pass|fail)\ combination=([^[:space:]]+)\ duration_ms=([0-9]+)\ liveness_interval_ms=([0-9]+)\ checks=([0-9]+)\ failures=([0-9]+)\ watchdog_failures=([0-9]+)\ liveness_failures=([0-9]+)$ ]]; then
        status=${BASH_REMATCH[1]}; [ "${BASH_REMATCH[2]}" = "$combination" ] || return 1
        duration=${BASH_REMATCH[3]}; [ "${BASH_REMATCH[4]}" = "$liveness" ] || return 1
        checks=${BASH_REMATCH[5]}; failures=${BASH_REMATCH[6]}
        watchdog=${BASH_REMATCH[7]}; liveness_failures=${BASH_REMATCH[8]}
    else
        return 1
    fi
    case "$mode" in
        pass)
            [ "$status" = pass ] && [ "$duration" = "$requested_duration" ] \
                && [ "$checks" -gt 0 ] && [ "$failures" -eq 0 ] \
                && [ "$watchdog" -eq 0 ] && [ "$liveness_failures" -eq 0 ]
            ;;
        fail)
            [ "$status" = fail ] && [ "$duration" = "$requested_duration" ] \
                && [ "$checks" -gt 0 ] && [ "$failures" -gt 0 ] \
                && [ "$watchdog" -gt 0 ]
            ;;
        *) return 2 ;;
    esac
}

pic12f675_mutation_has_signature() {
    local signature=$1 command=$2 log=$3 fault_label assertion variant count
    case "$signature" in
        fault:*)
            fault_label=${signature#fault:}
            mutation_command_assignment "$command" PIC12F675_TARGET_VARIANT || return 1
            variant=$MUTATION_COMMAND_ASSIGNMENT
            awk -v label="$fault_label" '
                BEGIN {
                    prefix = "inject " label
                    failure = "FAIL: 0 resets in 2000 ms (want exactly 1)  [gate did not fire?]"
                }
                {
                    line = $0
                    sub(/^[[:space:]]*/, "", line)
                    if (index(line, prefix) == 1 &&
                            substr(line, length(prefix) + 1, 1) ~ /[[:space:]]/) {
                        if (getline > 0 && index($0, failure) > 0) found = 1
                    }
                }
                END { exit(found ? 0 : 1) }
            ' "$log" \
                && grep -Eq "^PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=${variant} status=fail checks=38 failures=[1-9][0-9]*$" "$log"
            ;;
        gpsim:press-led)
            assertion='FAIL: PRESS1: LED (GP0) should be on mid-press (toggle-on-press)'
            grep -Fq "$assertion" "$log" \
                && pic12f675_gpsim_results_complete fail "$log"
            ;;
        gpsim:press-early)
            assertion='FAIL: PRESS1_EARLY: LED (GP0) on too early'
            grep -Fq "$assertion" "$log" \
                && pic12f675_gpsim_results_complete fail "$log"
            ;;
        lockstep:divergence)
            mutation_command_assignment "$command" PIC12F675_TARGET_VARIANT || return 1
            variant=$MUTATION_COMMAND_ASSIGNMENT
            grep -Fq 'FAIL: lock-step divergence at iter ' "$log" \
                && grep -Eq "^PIC_TARGET_RESULT format=1 device=pic12f675 lane=lockstep variant=${variant} status=fail checks=3005 failures=[1-9][0-9]*$" "$log"
            ;;
        # NB: deliberately NOT named fault:* -- the generic fault:*) case above
        # matches that whole prefix first and would swallow this signature.
        #
        # Two independent oracles now enforce the 4 ms floor on this part: the
        # target-I/O lane's explicit minimum check, and the fault lane's
        # measurement of the recovery actuation the F1 policy depends on
        # (docs/relay_coil_fault_correction.md). The aggregate is fail-closed
        # and runs fault BEFORE io, so a sub-minimum pulse is reported by the
        # fault lane and the io lane never runs -- which is why this signature
        # names the fault lane. The io minimum check still runs, and still
        # passes, on every clean invocation of the aggregate.
        resync:minimum-pulse)
            mutation_command_assignment "$command" PIC12F675_TARGET_VARIANT || return 1
            variant=$MUTATION_COMMAND_ASSIGNMENT
            [ "$variant" = tq2_l2_5v_relay ] \
                && grep -Eq 'FAIL: init=0x[0-9a-f]{2} requested=0x[0-9a-f]{2} read=0x[0-9a-f]{2} injection=1 deenergized=1 deenergize-cycles=[1-9][0-9]* .*resets=1 reset-coil-ms=[0-3]\.[0-9]{3} ' "$log" \
                && grep -Eq "^PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=fail checks=43 failures=[1-9][0-9]*$" "$log"
            ;;
        soak:wdt-reset)
            grep -Fq 'SOAK FAIL [' "$log" \
                && grep -Fq 'unexpected WDT reset' "$log" \
                && pic12f675_soak_result_complete fail "$command" "$log"
            ;;
        resync:coil)
            mutation_command_assignment "$command" PIC12F675_TARGET_VARIANT || return 1
            variant=$MUTATION_COMMAND_ASSIGNMENT
            [ "$variant" = tq2_l2_5v_relay ] \
                && grep -Eq 'FAIL: init=0x[0-9a-f]{2} requested=0x[0-9a-f]{2} read=0x[0-9a-f]{2} injection=1 deenergized=0 deenergize-cycles=0 ' "$log" \
                && grep -Eq "^PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=fail checks=43 failures=[1-9][0-9]*$" "$log"
            ;;
        resync:physical-coil)
            mutation_command_assignment "$command" PIC12F675_TARGET_VARIANT || return 1
            variant=$MUTATION_COMMAND_ASSIGNMENT
            [ "$variant" = tq2_l2_5v_relay ] \
                && grep -Fq 'fixture: COUT and physical GP2 were HIGH before escalation; latch-only clear left GP2 at ' "$log" \
                && grep -Eq 'FAIL: init=0x[0-9a-f]{2} requested=0x[0-9a-f]{2} read=0x[0-9a-f]{2} injection=1 deenergized=0 deenergize-cycles=0 partial-clear=0 spin=1 GP1=0\.[0-9]{3}V GP2=[4-9]\.[0-9]{3}V ' "$log" \
                && grep -Eq "^PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=fail checks=43 failures=[1-9][0-9]*$" "$log"
            ;;
        # B1. The sibling of host:atomic-clear, on the other obligation of the
        # SAME single whole-port write: that write publishes every shadow bit,
        # so parked GP4 must already be low in the shadow it publishes. Only the
        # pre-spin physical-pin read can fail here -- the reset still fires and
        # both coils are still cleared -- so this signature names that one
        # assertion by text and requires the two CD4053 variants clean.
        host:parked-output)
            [ "$command" = pic12f675-coverage-check-fw ] || return 1
            count=$(grep -c '^PIC shipping-source coverage harness: 86 checks, 0 failures$' \
                "$log" || true)
            [ "$count" -eq 2 ] \
                && grep -Fq 'parked GP4 shadow (intent) fault must force the fail-safe reset with parked GP4 physically low before the spin' \
                    "$log" \
                && grep -Fq 'PIC shipping-source coverage harness: 105 checks, 1 failures' "$log"
            ;;
        host:atomic-clear)
            [ "$command" = pic12f675-coverage-check-fw ] || return 1
            count=$(grep -c '^PIC shipping-source coverage harness: 86 checks, 0 failures$' \
                "$log" || true)
            [ "$count" -eq 2 ] \
                && grep -Fq 'relay reassert from shadow coils 02 must clear both bits' "$log" \
                && grep -Fq 'relay reassert from shadow coils 04 must clear both bits' "$log" \
                && grep -Fq 'relay reassert from shadow coils 06 must clear both bits' "$log" \
                && [ "$(grep -c 'relay reassert from shadow coils .* must clear both bits' \
                    "$log" || true)" -eq 3 ] \
                && grep -Fq 'PIC shipping-source coverage harness: 105 checks, 3 failures' "$log"
            ;;
        *) return 2 ;;
    esac
}

pic12f675_mutation_completed_cleanly() {
    local command=$1 log=$2 variant count
    case "$command" in
        pic12f675-test-gpsim)
            pic12f675_gpsim_results_complete pass "$log"
            ;;
        *pic12f675-test-target)
            mutation_command_assignment "$command" PIC12F675_TARGET_VARIANT || return 1
            variant=$MUTATION_COMMAND_ASSIGNMENT
            grep -Fq "=== PIC12F675 target fault/lock-step/I-O PASS (variant $variant): PIC12F675_MATRIX_SHA256 " "$log"
            ;;
        *pic12f675-test-soak)
            pic12f675_soak_result_complete pass "$command" "$log"
            ;;
        pic12f675-coverage-check-fw)
            count=$(grep -c '^PIC shipping-source coverage harness: 86 checks, 0 failures$' \
                "$log" || true)
            [ "$count" -eq 2 ] \
                && grep -Fq 'PIC shipping-source coverage harness: 105 checks, 0 failures' "$log" \
                && grep -Fq 'OK: all PIC shipping-source lines are covered except the documented reset path.' "$log" \
                && grep -Fq 'PIC12F675 coverage-oracle negative probe: PASS' "$log"
            ;;
        *) return 2 ;;
    esac
}

pic12f675_classify_checker_result() {
    local rc=$1 signature=$2 command=$3 log=$4
    PIC12F675_CHECKER_OUTCOME=checker-error
    PIC12F675_CHECKER_DIAGNOSTIC=
    if mutation_checker_status_is_infrastructure_error "$rc"; then
        PIC12F675_CHECKER_OUTCOME=infrastructure-error
    # A complete named behavioral verdict proves every required variant compiled
    # and ran. Prefer that stronger evidence to an incidental compiler-shaped
    # diagnostic elsewhere in the Make log.
    elif [ "$rc" -ne 0 ] \
            && pic12f675_mutation_has_signature "$signature" "$command" "$log"; then
        PIC12F675_CHECKER_OUTCOME=killed
    elif PIC12F675_CHECKER_DIAGNOSTIC=$(grep -Em1 \
            '^FAIL: variant (cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay) did not compile for PIC12F675$' \
            "$log"); then
        PIC12F675_CHECKER_OUTCOME=compile-error
    elif { [ "$signature" = host:atomic-clear ] || [ "$signature" = host:parked-output ]; } \
            && PIC12F675_CHECKER_DIAGNOSTIC=$(grep -Em1 \
                ': (fatal )?error:|undefined reference|collect2: error:' "$log"); then
        PIC12F675_CHECKER_OUTCOME=compile-error
    elif [ "$rc" -eq 0 ]; then
        if pic12f675_mutation_completed_cleanly "$command" "$log"; then
            PIC12F675_CHECKER_OUTCOME=survived
        fi
    fi
}

probe_pic12f675_baseline() {
    local root=$1 simcal_log target baseline_log rc
    PIC12F675_OK=0
    PIC12F675_WHY="tools absent"

    if ! mutation_command_is_available "$PIC12F675_MUTATION_CC" \
            || [ ! -f "$PIC12F675_MUTATION_DFP/pic/include/proc/pic12f675.h" ] \
            || ! mutation_command_is_available "$PIC12F675_MUTATION_PYTHON" \
            || ! mutation_command_is_available python3; then
        echo "XC8/DFP/Python absent -> PIC12F675 mutants SKIPPED"
        return 1
    fi

    simcal_log="$root/.mutation-pic12f675-simcal-baseline.log"
    mutation_bounded "$MUTATION_MAKE" -C "$root" pic12f675-simcal STRICT_TOOLS=1 \
        >"$simcal_log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        MUT_BASELINE_FAILED=1
        if [ "$rc" -eq 124 ]; then
            PIC12F675_WHY="pic12f675-simcal baseline TIMEOUT"
        else
            PIC12F675_WHY="pic12f675-simcal baseline FAILED"
        fi
        echo "PIC12F675 simulator-image baseline failed (status $rc) -> mutants DISABLED"
        return 1
    fi
    if ! grep -Fq '=== PIC12F675 simulator images derived in ' "$simcal_log"; then
        MUT_BASELINE_FAILED=1
        PIC12F675_WHY="pic12f675-simcal baseline INCOMPLETE"
        echo "PIC12F675 simulator-image baseline emitted no completion record -> mutants DISABLED"
        return 1
    fi

    if ! mutation_command_is_available "$GPSIM" \
            || ! mutation_command_is_available "$PIC_SOAK_CXX" \
            || ! mutation_command_is_available "$PIC12F675_MUTATION_HOSTCC" \
            || ! mutation_command_is_available pkg-config \
            || [ ! -f "$PIC_SOAK_GPSIM_INC/sim_context.h" ] \
            || ! pkg-config --exists glib-2.0 2>/dev/null; then
        echo "gpsim/libgpsim/glib/C++ tools absent -> PIC12F675 mutants SKIPPED"
        return 1
    fi

    for target in "${PIC12F675_BASE_TARGETS[@]}"; do
        baseline_log="$root/.mutation-pic12f675-kill-target-baseline.log"
        run_mutation_make_command "$root" "$target" \
            "GPSIM=$GPSIM" STRICT_TOOLS=1 >"$baseline_log" 2>&1
        rc=$?
        if [ "$rc" -eq 0 ] \
                && pic12f675_mutation_completed_cleanly "$target" "$baseline_log"; then
            echo "baseline $target: PASS"
            continue
        fi
        MUT_BASELINE_FAILED=1
        if [ "$rc" -eq 124 ]; then
            PIC12F675_WHY="kill-target baseline TIMEOUT"
        elif [ "$rc" -eq 0 ]; then
            PIC12F675_WHY="kill-target baseline INCOMPLETE"
        else
            PIC12F675_WHY="kill-target baseline FAILED"
        fi
        echo "baseline $target: FAIL (status $rc, $PIC12F675_WHY)"
        return 1
    done

    PIC12F675_OK=1
    echo "XC8 + gpsim + libgpsim present, all baselines PASS -> PIC12F675 mutants ENABLED"
}

mutation_partial_result_is_allowed() {
    local pic_skipped=$1 xt_skipped=$2 allow_skip=$3 baseline_failed=$4
    [ "$baseline_failed" -eq 0 ] \
        && { [ "$pic_skipped" -eq 0 ] \
            || mutation_skip_is_allowed PIC "$allow_skip"; } \
        && { [ "$xt_skipped" -eq 0 ] \
            || mutation_skip_is_allowed ATtiny202 "$allow_skip"; }
}

unpack_mutation_job_spec() {
    local spec=$1 rest field
    local -a fields=()
    rest=$spec
    while [[ $rest == *"$US"* ]]; do
        field=${rest%%"$US"*}
        fields+=("$field")
        rest=${rest#*"$US"}
    done
    fields+=("$rest")
    if [ "${#fields[@]}" -ne 6 ] || [ -z "${fields[0]}" ] \
            || [ -z "${fields[1]}" ] || [ -z "${fields[3]}" ] \
            || [ -z "${fields[4]}" ] || [ -z "${fields[5]}" ]; then
        echo "ERROR: packed mutation job has a malformed field set" >&2
        return 1
    fi
    category=${fields[0]}; kind=${fields[1]}; arg=${fields[2]}
    file=${fields[3]}; sed_expr=${fields[4]}; desc=${fields[5]}
    # An unknown kind gets its own message rather than falling into the pair
    # check below: `*) return 1` leaves the function before the `||` runs, so a
    # kind this validator has never heard of would abort the whole run with no
    # diagnostic at all. That is exactly what a newly added lane looks like.
    case "$kind" in
        make|pictarget|avrxt|pic12f675) [ -n "$arg" ] ;;
        picgpsim|picsoak) [ -z "$arg" ] ;;
        *)  echo "ERROR: packed mutation job has an unknown kind: $kind" >&2
            return 1 ;;
    esac || {
        echo "ERROR: packed mutation job has an invalid kind/argument pair" >&2
        return 1
    }
}

publish_mutation_result() {
    local stem=$1 status=$2 output=$3 survivor=${4-}
    local out_tmp="$stem.out.tmp.$$" status_tmp="$stem.status.tmp.$$"
    if ! printf '%s\n' "$output" > "$out_tmp"; then return 1; fi
    case "$status" in
        survived)
            if [ -z "$survivor" ] \
                    || ! printf 'survived\n%s\n' "$survivor" > "$status_tmp"; then
                rm -f "$out_tmp" "$status_tmp"
                return 1
            fi
            ;;
        killed|errored)
            if ! printf '%s\n' "$status" > "$status_tmp"; then
                rm -f "$out_tmp" "$status_tmp"
                return 1
            fi
            ;;
        *)
            rm -f "$out_tmp" "$status_tmp"
            return 1
            ;;
    esac
    if ! mv "$out_tmp" "$stem.out" || ! mv "$status_tmp" "$stem.status"; then
        rm -f "$out_tmp" "$status_tmp"
        return 1
    fi
}

# Apply one mutation in a throwaway sandbox and run the mapped checker.
#   $1 idx  : 1-based mutant number (stable, assigned at dispatch time)
#   $2 kind : make | picgpsim | picsoak | pictarget | pic12f675
#   $3 arg  : make target (kind=make), PIC variant (kind=pictarget),
#             signature|make-command (kind=pic12f675), ignored otherwise
#   $4 file ; $5 sed-expr ; $6 description
# Runs in the background under the dispatch() pool, so it must NOT touch shared
# shell state. It records its verdict to two files under $RESULT_DIR, keyed by a
# zero-padded index (lexical order == numeric order):
#   $idx.status : first line = killed|survived|errored;
#                 second line (survived only) = "file: desc" for the survivor list
#   $idx.out    : the human-readable "[idx] ..." line, replayed in order after the
#                 pool drains so the log stays deterministic regardless of timing
# The main shell tallies these files after `wait`, so the summary is identical to
# a serial run.
run_mutant() {
    local idx="$1" kind="$2" arg="$3" file="$4" sed_expr="$5" desc="$6"
    local stem; stem="$RESULT_DIR/$(printf '%04d' "$idx")"

    local work
    if ! work="$(mktemp -d "$RESULT_DIR/mutant.XXXXXX")"; then
        publish_mutation_result "$stem" errored \
            "[$idx] ERROR  could not create mutation sandbox: $desc"
        return $?
    fi
    if ! copy_tree "$work"; then
        publish_mutation_result "$stem" errored \
            "[$idx] ERROR  could not populate mutation sandbox: $desc"
        local publish_rc=$?
        rm -rf "$work" || true
        return "$publish_rc"
    fi

    # Apply the mutation; confirm it actually changed the file.
    if ! sed -i "$sed_expr" "$work/$file"; then
        publish_mutation_result "$stem" errored \
            "[$idx] ERROR  applying sed to $file: $desc"
        local publish_rc=$?
        rm -rf "$work" || true
        return "$publish_rc"
    fi
    cmp -s "$work/$file" "$PROJ_DIR/$file"
    local cmp_rc=$?
    case "$cmp_rc" in
        0)
            publish_mutation_result "$stem" errored \
                "[$idx] ERROR  mutation did not change $file (pattern stale?): $desc"
            local publish_rc=$?
            rm -rf "$work" || true
            return "$publish_rc"
            ;;
        1) ;;
        *)
            publish_mutation_result "$stem" errored \
                "[$idx] ERROR  could not compare mutated source $file: $desc"
            local publish_rc=$?
            rm -rf "$work" || true
            return "$publish_rc"
            ;;
    esac

    # Run the mapped checker. PIC12F675 is stricter than the legacy lanes: its
    # row names a behavioral signature, and only that signature can earn kill
    # credit. Other lanes retain their established nonzero-exit contract.
    local label rc checker_log pic12_signature pic12_command
    case "$kind" in
        make)
            label="$arg"
            run_mutation_make_command "$work" "$arg" >/dev/null 2>&1; rc=$?
            ;;
        picgpsim)
            label="pic10f322-test-gpsim"
            pic_gpsim_run "$work"; rc=$?
            ;;
        picsoak)
            label="pic10f322-test-soak"
            mutation_bounded "$MUTATION_MAKE" -C "$work" pic10f322-test-soak \
                PIC10F322_SOAK_DURATION_MS="$PIC_SOAK_MUT_MS" \
                PIC10F322_SOAK_LIVENESS_INTERVAL_MS="$PIC_SOAK_MUT_LIVENESS_MS" \
                PIC10F322_SOAK_VARIANT=cd4053_simple \
                >/dev/null 2>&1; rc=$?
            ;;
        pictarget)
            label="pic10f322-test-target($arg)"
            mutation_bounded "$MUTATION_MAKE" -C "$work" PIC10F322_TARGET_VARIANT="$arg" pic10f322-test-target >/dev/null 2>&1; rc=$?
            ;;
        avrxt)
            # Same shape as `make`, plus the two absolute tool paths the sandbox
            # cannot supply itself (see the XT knobs at the top). Intentional
            # word splitting on $arg: each entry is optional VAR=value
            # assignments followed by one Make target, never shell metacharacters.
            label="$arg"
            mutation_bounded "$MUTATION_MAKE" -C "$work" $arg \
                XT_DFP="$xt_dfp_abs" \
                YASIMAVR_VENV="$xt_yasimavr_venv_abs" \
                OBJDUMP="$XT_MUTATION_OBJDUMP" \
                >/dev/null 2>&1; rc=$?
            ;;
        pic12f675)
            pic12_signature=${arg%%|*}
            pic12_command=${arg#*|}
            if [ "$pic12_signature" = "$arg" ] || [ -z "$pic12_signature" ] \
                    || [ -z "$pic12_command" ]; then
                publish_mutation_result "$stem" errored \
                    "[$idx] ERROR  malformed PIC12F675 signature/command: $desc"
                local publish_rc=$?
                rm -rf "$work" || true
                return "$publish_rc"
            fi
            label="$pic12_command [$pic12_signature]"
            checker_log="$work/pic12f675-mutation-checker.log"
            run_mutation_make_command "$work" "$pic12_command" \
                "GPSIM=$GPSIM" STRICT_TOOLS=1 >"$checker_log" 2>&1; rc=$?
            ;;
        *)
            publish_mutation_result "$stem" errored \
                "[$idx] ERROR  unknown mutation checker kind '$kind': $desc"
            local publish_rc=$?
            rm -rf "$work" || true
            return "$publish_rc"
            ;;
    esac

    if [ "$kind" != pic12f675 ] \
            && mutation_checker_status_is_infrastructure_error "$rc"; then
        publish_mutation_result "$stem" errored \
            "[$idx] ERROR  checker infrastructure status $rc ($label): $desc"
        local publish_rc=$?
        rm -rf "$work" || true
        return "$publish_rc"
    fi
    if [ "$kind" = pic12f675 ]; then
        pic12f675_classify_checker_result "$rc" "$pic12_signature" \
            "$pic12_command" "$checker_log"
        case "$PIC12F675_CHECKER_OUTCOME" in
            killed)
                publish_mutation_result "$stem" killed \
                    "[$idx] killed   ($label): $desc"
                ;;
            survived)
                publish_mutation_result "$stem" survived \
                    "[$idx] SURVIVED ($label): $desc" "$file: $desc"
                ;;
            infrastructure-error)
                publish_mutation_result "$stem" errored \
                    "[$idx] ERROR  checker infrastructure status $rc ($label): $desc"
                ;;
            compile-error)
                publish_mutation_result "$stem" errored \
                    "[$idx] ERROR  mutant did not compile ($label): $desc; first diagnostic: ${PIC12F675_CHECKER_DIAGNOSTIC:-unavailable}"
                ;;
            checker-error)
                publish_mutation_result "$stem" errored \
                    "[$idx] ERROR  checker did not produce the named complete verdict ($label): $desc"
                ;;
        esac
        local publish_rc=$?
        rm -rf "$work" || true
        return "$publish_rc"
    fi
    if [ "$rc" -eq 0 ]; then
        publish_mutation_result "$stem" survived \
            "[$idx] SURVIVED ($label): $desc" "$file: $desc"
    else
        publish_mutation_result "$stem" killed \
            "[$idx] killed   ($label): $desc"
    fi
    local publish_rc=$?
    rm -rf "$work" || true
    return "$publish_rc"
}

# --- PIC shell mutants (src/bypass_mcu_pic10f322.c) ----------------------------
# The PIC shell target-level mutants drive the real XC8-built HEX in gpsim and
# libgpsim. They are GATED on the PIC toolchain being present AND the unmutated tree
# genuinely PASSING (see the PIC toolchain probe below): gpsim/XC8/gpsim-dev
# absence makes the targets skip (exit 0), which would otherwise read as a false
# "survivor". gpsim's WDT calibration is wrong (~1.057s vs the silicon ~256ms)
# and it does not model the analog BOR, so WDT-timing / BOR / tick-RATE mutants
# are deliberately excluded; only faults observable as register state or a
# qualitative WDT reset are included.
#
# Each entry: file<TAB>sed-expression<TAB>description. These are killed by the
# PORTA/LATA assertions in test/pic/run_gpsim_test.sh, including the mid-debounce
# PRESS1_EARLY cadence checkpoint.
PIC_GPSIM_MUTATIONS=(
"src/bypass_mcu_pic10f322.c	s@LATA |=  (uint8_t)(1U << LED_PIN)@LATA \&= (uint8_t)~(1U << LED_PIN)@	PIC set_engaged LED inverted (LATA RA0 stays dark); ENGAGED checkpoint catches it"
"src/bypass_mcu_pic10f322.c	s@LATA &= (uint8_t)~(1U << LED_PIN)@LATA |= (uint8_t)(1U << LED_PIN)@	PIC set_bypass LED clear inverted (RA0 stuck on); INIT/BYPASS_AGAIN checkpoints catch it"
"src/bypass_mcu_pic10f322.c	s@(0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA \& (uint8_t)(1U << FOOTSW_PIN)))@	PIC footswitch read polarity inverted (RA3 sense flipped -> toggles on release, not press); PRESS1 LED-on (toggle-on-press) checkpoint catches it"
"src/bypass_mcu_pic10f322.c	s@LATA |=  (uint8_t)(1U << pin)@LATA \&= (uint8_t)~(1U << pin)@	PIC control-pin drive inverted (LATA bit never set); ENGAGED full-LATA (0x3) check catches it"
"src/bypass_mcu_pic10f322.c	s@T2CON = TMR2_T2CON_CONFIG;@T2CON = 0x03U;@	PIC TMR2 tick disabled (TMR2ON = bit2 cleared); main loop hangs in hw_wait_for_tick -> never toggles"
"src/bypass_mcu_pic10f322.c	s@PIR1bits.TMR2IF = 0;@@	PIC TMR2IF tick-flag clear removed: loop free-runs and PRESS1_EARLY catches the too-fast debounce"
)

# Mutants killed by the fail-closed PIC target aggregate (fault + lock-step +
# target I/O). Each entry: file<TAB>sed-expression<TAB>variant<TAB>description.
PIC_TARGET_MUTATIONS=(
"src/bypass_mcu_pic10f322.c	s@hw_outputs_reassert_safe();@@	tq2_l2_5v_relay	fail-safe coil de-energization removed from hw_force_wdt_reset(); inject_relay_resync_case never observes the coils go low before the reset spin"
"src/bypass_mcu_pic10f322.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	cd4053_simple	PIC pull-up init regressed to read-modify-write; exact WPUA state can preserve unexpected output-pin latches"
"src/bypass_mcu_pic10f322.c	s@(uint8_t)(WPUA & 0x0FU)@(uint8_t)(WPUA \& (uint8_t)(1U << FOOTSW_PIN))@	cd4053_simple	PIC exact WPUA guard weakened to RA3-present only; extra RA0..RA2 latches go undetected"
"src/bypass_mcu_pic10f322.c	s@(uint8_t)(0x0FU ^ BYPASS_OUTPUT_DDR_MASK));@actual_direction_mask);@	cd4053_simple	PIC exact-TRISA predicate removed: spare RA2 direction corruption evades the remaining required-subset check"
"src/bypass_mcu_pic10f322.c	s@LATA & (uint8_t)BYPASS_OUTPUT_DDR_MASK@LATA \& (uint8_t)0x03U@	cd4053_simple	PIC output-latch mask omits RA2; an unexpected high spare/control/coil latch goes undetected"
"src/bypass_mcu_pic10f322.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	cd4053_simple	PIC ANSELA sanity mask narrowed to RA0 only; RA1/RA2 analog re-selection undetected"
"src/bypass_output_cd4053_with_mute.c	s@hw_led_pin_set_low();          // dark status LED@hw_pin_set_high(CD4053_CTL1);  // MUTANT: reassert ENGAGED at startup\\n    hw_pin_set_high(CD4053_CTL2);\\n\\n    hw_led_pin_set_low();          // dark status LED@	cd4053_with_mute	PIC cd4053_with_mute startup reasserts ENGAGED before MUTE; target I/O startup trace catches it"
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	cd4053_with_mute	PIC cd4053_with_mute pre-switch mute window shortened; target I/O pulse-width check catches it"
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	tq2_l2_5v_relay	PIC relay coil pulse shortened below datasheet minimum; target I/O pulse-width check catches it"
# F2 context-SEU: delete the polled shadow clause; killed by the aggregate fault leg.
"src/bypass_mcu_pic10f322.c	s@(ctx_check_ != debounce_ctx_check_word(next_ctx)) ||@(0U != 0U) ||@	cd4053_simple	PIC F2 shadow clause deleted from the polled sanity gate (the FIRST clause, before integrate); the in-range debounce SEU is no longer caught and the target fault leg ctx.debounce.inrange case sees 0 resets."
)

# WDT-liveness mutant: gpsim's ~200ms functional run is too short to see an
# un-pet WDT fire (period ~1.057s), so this is killed by the libgpsim soak (which
# counts resets) over a short window > one WDT period. Gated additionally on
# gpsim-dev + glib + a C++ compiler.
# --- PIC10F320 mutants (merged 2026-07-26) -----------------------------------
# Split by what they NEED, not by what they test: the host lanes want only a C
# compiler, so they run wherever `make test` runs; the rest need XC8 + gpsim +
# libgpsim and are gated by the PIC10F320 probe below. Without that split the
# tool-dependent ones would "survive" on any box lacking the toolchain -- the
# exact false-pass the existing PIC probe was written to prevent.
PIC10F320_HOST_MUTATIONS=(
"src/bypass_mcu_pic10f320.c	s@++ctx_.debounce_counter@--ctx_.debounce_counter@	pic10f320-test-equiv	FW integrator: increment-on-press becomes decrement (never reaches threshold)"
"src/bypass_mcu_pic10f320.c	s@ctx_.debounce_counter >= PRESSED_THRESH@ctx_.debounce_counter > PRESSED_THRESH@	pic10f320-test-equiv	FW press threshold off-by-one (>= becomes >): 1-tick latency divergence"
"src/bypass_mcu_pic10f320.c	s@if (0U == ctx_.debounce_counter)@if (0U != ctx_.debounce_counter)@	pic10f320-test-equiv	FW release re-arm condition inverted (lock-out never clears / clears wrongly)"
"src/bypass_mcu_pic10f320.c	s@#define PRESSED_THRESH  (8U)@#define PRESSED_THRESH  (4U)@	pic10f320-test-equiv	FW press threshold shortened 8->4 (diverges from the model's 8)"
"src/bypass_mcu_pic10f320.c	s@#define RELEASE_THRESH  (25U)@#define RELEASE_THRESH  (15U)@	pic10f320-test-equiv	FW release lock-out shortened 25->15 (diverges from the model)"
"src/bypass_mcu_pic10f320.c	s@ctx_.program_state = RELEASE_DEBOUNCE_WAIT;@ctx_.program_state = PRESS_DEBOUNCE_WAIT;@	pic10f320-test-equiv	FW power-on-pressed: wrong program_state (held switch could spuriously engage)"
"src/bypass_mcu_pic10f320.c	s@(uint8_t)(0x0FU ^ BYPASS_OUTPUT_DDR_MASK)@(uint8_t)(TRISA \& 0x0FU)@	pic10f320-test-fault-variants	FW output-pin SEU check neutered (exact-TRISA compare made a tautology; no direction fault ever detected)"
"src/bypass_mcu_pic10f320.c	s@(0U == wpu_global)@1U@	pic10f320-test-fault-variants	FW global footswitch pull-up SEU check neutered (nWPUEN corruption never detected)"
"src/bypass_mcu_pic10f320.c	s@(ctx_.effect_state > ENGAGED)@(ctx_.effect_state > 99U)@	pic10f320-test-fault-variants	FW effect_state range guard defeated (corrupt effect_state never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(ctx_.debounce_counter > RELEASE_THRESH)@(ctx_.debounce_counter > 255U)@	pic10f320-test-fault-variants	FW counter range guard defeated (corrupt debounce_counter never forces reset)"
"src/bypass_mcu_pic10f320.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	pic10f320-test-fault-variants	FW pull-up init regressed to read-modify-write: WPUA reset value 0x0F preserved instead of exact RA3-only 0x08"
"src/bypass_mcu_pic10f320.c	s@WPUA \& 0x0FU@WPUA \& (1U << FOOTSW_PIN)@	pic10f320-test-fault-variants	FW pull-up integrity guard masks away unexpected RA0..RA2 WPUA latches"
"src/bypass_mcu_pic10f320.c	s@(HFINTOSC_2MHZ_IRCF == OSCCONbits.IRCF)@1U@	pic10f320-test-fault-variants	FW clock-select (OSCCON IRCF) SEU guard defeated (corrupt clock never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(WDT_WDTPS_256MS == WDTCONbits.WDTPS)@1U@	pic10f320-test-fault-variants	FW watchdog-period (WDTCON WDTPS) SEU guard defeated (corrupt WDT period never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(TMR2_PR2_PERIOD == PR2)@1U@	pic10f320-test-fault-variants	FW tick-period (PR2) SEU guard defeated (corrupt 1 ms reload never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(TMR2_T2CON_CONFIG == T2CON)@1U@	pic10f320-test-fault-variants	FW tick-control (T2CON) SEU guard defeated (corrupt prescale/enable never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(0U == (uint8_t)(ANSELA & BYPASS_OUTPUT_DDR_MASK))@1U@	pic10f320-test-fault-variants	FW digital-port (ANSELA) SEU guard defeated (output pin re-selected analog never forces reset)"
"src/bypass_mcu_pic10f320.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	pic10f320-test-fault-variants	FW ANSELA sanity mask narrowed to RA0 only (RA1/RA2 analog re-selection undetected)"
"src/bypass_mcu_pic10f320.c	s@LATA |=  (uint8_t)(1U << LED_PIN)@LATA \&= (uint8_t)~(1U << LED_PIN)@	pic10f320-test-equiv	FW set_engaged LED output inverted (RA0 stays dark when ENGAGED)"
"src/bypass_mcu_pic10f320.c	s@hw_x4053_ctl_low();@hw_x4053_ctl_high();@	PIC10F320_VARIANT=cd4053_simple pic10f320-test-actuation	FW CD4053 control routed the wrong way (set_engaged drives the bypass level); settled ENGAGED LATA 0x1 not 0x3 (RA0 unaffected, so equiv/gpsim-RA0 miss it; killed by the actuation settled-LATA check)"
"src/bypass_mcu_pic10f320.c	s@static void hw_x4053_ctl_high(void) { LATA \&= (uint8_t)~(1U << CD4053_PIN); }@static void hw_x4053_ctl_high(void) { LATA |=  (uint8_t)(1U << CD4053_PIN); }@	PIC10F320_VARIANT=cd4053_simple pic10f320-test-actuation	FW CD4053 control-pin drive polarity inverted at the definition (ctl_high drives the pin HIGH not LOW); bypass control pin settles wrong (BYPASS 0x2 not 0x0), RA0 unaffected so equiv/gpsim-RA0 miss it"
"src/bypass_mcu_pic10f320.c	s@(0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA \& (uint8_t)(1U << FOOTSW_PIN)))@	pic10f320-test-equiv	FW footswitch read polarity inverted (toggles on release, not press)"
"src/bypass_mcu_pic10f320.c	s@hw_relay_set_pin_set_high(); // pulse set coil@hw_relay_reset_pin_set_high(); // MUTANT@	PIC10F320_VARIANT=tq2_l2_5v_relay pic10f320-test-actuation	FW relay ENGAGE pulses the RESET coil instead of SET (relay latches backwards; settles to same LATA, so equiv/gpsim miss it)"
"src/bypass_mcu_pic10f320.c	s@hw_relay_reset_pin_set_high(); // pulse reset coil@hw_relay_set_pin_set_high(); // MUTANT@	PIC10F320_VARIANT=tq2_l2_5v_relay pic10f320-test-actuation	FW relay BYPASS pulses the SET coil instead of RESET (relay latches backwards)"
"src/bypass_mcu_pic10f320.c	/hw_force_wdt_reset(void)/,/^}/s@    set_relay_coils_low();@@	PIC10F320_VARIANT=tq2_l2_5v_relay pic10f320-test-fault-host	FW fail-safe coil de-energization removed from hw_force_wdt_reset(); host latch injections are still energized where the reset spin is abandoned"
"src/bypass_mcu_pic10f320.c	s@    LATA \&= (uint8_t)~((1U << RELAY_RESET_PIN) | (1U << RELAY_SET_PIN));@    LATA \&= (uint8_t)~(1U << RELAY_RESET_PIN); LATA \&= (uint8_t)~(1U << RELAY_SET_PIN); /* MUTANT: per-bit clear */@	PIC10F320_VARIANT=tq2_l2_5v_relay pic10f320-test-fault-host	FW one-write coil clear regressed to a per-bit clear of RESET then SET; with both coil latches injected the SET coil is still driven after the clear began, which the host lane sees as a partially cleared coil latch"
"src/bypass_mcu_pic10f320.c	s@    diff |= (uint8_t)(LATA & (uint8_t)((1U << RELAY_RESET_PIN) |@    diff |= (uint8_t)(LATA \& (uint8_t)((0U \& RELAY_RESET_PIN) |@	PIC10F320_VARIANT=tq2_l2_5v_relay pic10f320-test-fault-host	FW relay coil guard weakened to the SET bit only; an injected RESET coil no longer escalates"
"src/bypass_mcu_pic10f320.c	s@#  define CD4053_MUTE_DELAY_MS (5U)@#  define CD4053_MUTE_DELAY_MS (0U)@	PIC10F320_VARIANT=cd4053_with_mute pic10f320-test-actuation	FW cd4053_with_mute pre-switch mute window defeated (5->0 ms): audible click on every switch"
"src/bypass_mcu_pic10f320.c	s@#  define CD4053_CTL1     (1U) // RA1@#  define CD4053_CTL1     (2U) // MUTANT@;s@#  define CD4053_CTL2     (2U) // RA2@#  define CD4053_CTL2     (1U) // MUTANT@	PIC10F320_VARIANT=cd4053_with_mute pic10f320-test-actuation	FW cd4053_with_mute CTL1/CTL2 pins swapped (mute applied to wrong control; mid-mute LATA pattern wrong, settles to same LATA so equiv/gpsim miss it)"
"src/bypass_mcu_pic10f320.c	s@    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@    hw_x4053_ctl1_low(); // MUTANT: reassert ENGAGED at startup\\n    hw_x4053_ctl2_low();\\n\\n    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@	PIC10F320_VARIANT=cd4053_with_mute pic10f320-test-actuation	FW cd4053_with_mute startup reasserts ENGAGED before MUTE, traversing INVALID/ENGAGED routing instead of remaining continuously in BYPASS"
)

PIC10F320_TOOL_MUTATIONS=(
"src/bypass_mcu_pic10f320.c	s@PIR1bits.TMR2IF = 0;@@	pic10f320-test-gpsim	FW TMR2IF tick-flag clear removed: 1 ms poll never re-blocks, loop free-runs, debounce window collapses (host forces TMR2IF=1, so only gpsim's PRESS1_EARLY catches it)"
"src/bypass_mcu_pic10f320.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	PIC10F320_VARIANT=cd4053_simple PIC10F320_TARGET_VARIANT=cd4053_simple pic10f320-test-target	TARGET pull-up init regressed to read-modify-write; exact startup WPUA check catches retained RA0..RA2 latches"
"src/bypass_mcu_pic10f320.c	s@wpua_latches == (uint8_t)(1U << FOOTSW_PIN)@0U != (wpua_latches \& (uint8_t)(1U << FOOTSW_PIN))@	PIC10F320_VARIANT=cd4053_simple PIC10F320_TARGET_VARIANT=cd4053_simple pic10f320-test-target	TARGET exact WPUA guard weakened to RA3-present only; target fault injections catch extra output-pin latches"
"src/bypass_mcu_pic10f320.c	s@static uint8_t hw_output_pins_intact(void) {@static uint8_t hw_output_pins_intact(void) { return 1U;@	PIC10F320_VARIANT=cd4053_simple PIC10F320_TARGET_VARIANT=cd4053_simple pic10f320-test-target	TARGET output-direction guard disabled; simulated-core TRISA injections no longer recover"
"src/bypass_mcu_pic10f320.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	PIC10F320_VARIANT=cd4053_simple PIC10F320_TARGET_VARIANT=cd4053_simple pic10f320-test-target	TARGET ANSELA sanity mask narrowed to RA0; RA1/RA2 analog re-selection goes undetected"
"src/bypass_mcu_pic10f320.c	s@    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@    hw_x4053_ctl1_low(); // MUTANT: reassert ENGAGED at startup\n    hw_x4053_ctl2_low();\n\n    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@	PIC10F320_VARIANT=cd4053_with_mute PIC10F320_TARGET_VARIANT=cd4053_with_mute pic10f320-test-target	TARGET mute startup reasserts ENGAGED before MUTE; physical startup transition trace catches it"
"src/bypass_mcu_pic10f320.c	s@#  define CD4053_MUTE_DELAY_MS (5U)@#  define CD4053_MUTE_DELAY_MS (1U)@	PIC10F320_VARIANT=cd4053_with_mute PIC10F320_TARGET_VARIANT=cd4053_with_mute pic10f320-test-target	TARGET mute window shortened below 5ms; cycle-exact target I/O timing catches it"
"src/bypass_mcu_pic10f320.c	s@#  define TQ2_L2_5V_PULSE_MS (12U)@#  define TQ2_L2_5V_PULSE_MS (1U)@	PIC10F320_VARIANT=tq2_l2_5v_relay PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay pic10f320-test-target	TARGET relay pulse shortened below the 4ms datasheet minimum; cycle-exact target I/O timing catches it"
"src/bypass_mcu_pic10f320.c	/hw_force_wdt_reset(void)/,/^}/s@    set_relay_coils_low();@@	PIC10F320_VARIANT=tq2_l2_5v_relay PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay pic10f320-test-target	TARGET fail-safe coil de-energization removed from hw_force_wdt_reset(); the real image spins out its watchdog with modeled PORTA still energized, so the resync cases never see the coils go low"
"src/bypass_mcu_pic10f320.c	s@    LATA \&= (uint8_t)~((1U << RELAY_RESET_PIN) | (1U << RELAY_SET_PIN));@    LATA \&= (uint8_t)~(1U << RELAY_RESET_PIN); LATA \&= (uint8_t)~(1U << RELAY_SET_PIN); /* MUTANT: per-bit clear */@	PIC10F320_VARIANT=tq2_l2_5v_relay PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay pic10f320-test-target	TARGET one-write coil clear regressed to a per-bit clear of RESET then SET; the real image sheds the two injected coil bits on separate instructions and the instruction-granular resync sampling catches the intermediate state"
"src/bypass_mcu_pic10f320.c	s@(1U << RELAY_SET_PIN)));@(0U \& RELAY_SET_PIN)));@	PIC10F320_VARIANT=tq2_l2_5v_relay PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay pic10f320-test-target	TARGET relay coil guard weakened to the RESET bit only; an injected SET coil no longer escalates (mirror of the host-lane mutant that drops the RESET bit)"
"src/bypass_mcu_pic10f320.c	/void main(void)/,\$s@CLRWDT();@(void)0; /* MUTANT: no main-loop WDT pet */@	PIC10F320_VARIANT=cd4053_simple PIC10F320_SOAK_DURATION_MS=$PIC_SOAK_MUT_MS PIC10F320_SOAK_LIVENESS_INTERVAL_MS=$PIC_SOAK_MUT_MS pic10f320-test-soak	SOAK main-loop WDT pet removed; reset notifier catches the un-pet watchdog within the short mutation window"
)

PIC_SOAK_MUTATIONS=(
"src/bypass_mcu_pic10f322.c	s@{ CLRWDT(); }@{ (void)0; /* MUTANT: no WDT pet */ }@	PIC WDT pet (CLRWDT) removed; soak reset counter trips within ~1s of an un-pet WDT"
)

# --- PIC12F675 mutants --------------------------------------------------------
# One target-tool table, not three, because this part has ONE toolchain gate: every kill
# target below needs XC8 plus gpsim or libgpsim, and pic12f675-simcal on top of
# that. Splitting this table by lane the way the PIC10F322 tables do would buy
# nothing. Two PIC12F675 shell faults that shipping-source coverage can prove
# without XC8 live in the always-run core/host table instead.
#
# Chosen for what each fault actually perturbs, and weighted toward what this
# part has that the 10F32x parts do not:
#   * the SRAM output shadow (no LATx), so "the port did not follow intent" is
#     an expressible fault here and a tautology on the 322;
#   * the software sub-tick counter, since TMR0 has no period register;
#   * the comparator and the OSCCAL trim snapshot, neither of which exists on
#     the 322 -- its analogues are ANSELA alone and a constant OSCCON compare;
#   * ANSEL's off-by-one mapping (GPIO bit 4 -> ANS3), which is exactly the kind
#     of thing a mask narrowed by hand gets wrong.
# Copying the 322's list verbatim would have re-proved the shared pure core and
# left every one of those unexercised.
#
# Each entry: file<TAB>sed-expression<TAB>make-args<TAB>behavior-signature<TAB>
# description. The make
# args are the same shape as the PIC10F320 tool table's: optional VAR=value
# assignments followed by exactly one target, tokenized by the shared helper.
# The signature names positive oracle output required before a failed checker can
# earn kill credit. Compile failures and unrelated nonzero exits are errors.
PIC12F675_MUTATIONS=(
"src/bypass_mcu_pic12f675.c	s@hw_outputs_reassert_safe();@@	PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target	resync:coil	FW latch clear removed from the emergency helper; ordinary relay fault cases never observe both intent and physical pins idle before the reset spin, failing the relay fault lane at checks=43"
"src/bypass_mcu_pic12f675.c	/static void hw_emergency_outputs_quiesce/,/^}/s@#if defined(TQ2_L2_5V_RELAY)@#if 0 /* MUTANT: latch-only emergency path */@	PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target	resync:physical-coil	FW emergency path reduced to the ordinary latch clear; comparator-owned physical GP2 remains high at the watchdog spin despite low shadow intent"
"src/bypass_mcu_pic12f675.c	s@(shadow_high_mask == expected_high_mask) &&@((shadow_high_mask == expected_high_mask) || (shadow_high_mask != expected_high_mask)) \&\&@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:shadow.expected	TARGET shadow-versus-expected guard tautologized while retaining both operands; the shadow.expected fault (shadow+port driven high, ctx_ untouched) isolates this clause F2-blind, so only it catches the reset"
"src/bypass_mcu_pic12f675.c	s@gpio_shadow_ |= (uint8_t)(1U << LED_PIN);@gpio_shadow_ \&= (uint8_t)~(1U << LED_PIN);@	pic12f675-test-gpsim	gpsim:press-led	FW set_engaged LED inverted at the shadow (GP0 stays dark); the PRESS1 toggle-on-press assertion catches it"
"src/bypass_mcu_pic12f675.c	s@(0U == (GPIO & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (GPIO \& (uint8_t)(1U << FOOTSW_PIN)))@	pic12f675-test-gpsim	gpsim:press-led	FW footswitch read polarity inverted (GP5 sense flipped -> toggles on release); PRESS1 toggle-on-press checkpoint catches it"
"src/bypass_mcu_pic12f675.c	s@#define TMR0_SUBTICKS_PER_TICK (4U)@#define TMR0_SUBTICKS_PER_TICK (1U)@	pic12f675-test-gpsim	gpsim:press-early	FW software sub-tick count 4->1: the tick becomes 256us, debounce completes 4x early; PRESS1_EARLY cadence checkpoint catches it (no PIC10F322 counterpart -- that part has a period register)"
"src/bypass_mcu_pic12f675.c	/static void hw_wait_for_tick/,/^}/s@        INTCONbits.T0IF = 0;@        (void)0; /* MUTANT: T0IF not cleared after sub-tick */@	pic12f675-test-gpsim	gpsim:press-early	FW T0IF re-arm removed from the polling loop: after the first overflow all remaining sub-ticks free-run and PRESS1_EARLY catches the collapsed debounce cadence"
"src/bypass_mcu_pic12f675.c	/void hw_pin_set_high/,/^}/s@GPIO = gpio_shadow_;@/* MUTANT: shadow never reaches the port */@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	lockstep:divergence	TARGET control-pin write never reaches GPIO -- a fault only a part with an SRAM shadow can express. The shell's own port-follows-shadow guard then resets every iteration, and lock-step sees the ctx_ divergence"
"src/bypass_mcu_pic12f675.c	s@        (uint8_t)(GPIO & (uint8_t)BYPASS_OUTPUT_DDR_MASK);@        (uint8_t)(gpio_shadow_ \& (uint8_t)BYPASS_OUTPUT_DDR_MASK);@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:GPIO.GP0	TARGET port-follows-shadow guard reads the shadow twice, making the comparison a tautology; physical-pin fault injections stop recovering"
"src/bypass_mcu_pic12f675.c	s@(actual_direction_mask == expected_direction_mask) &&@(1U != 0U) \&\&@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:TRISIO.GP4	TARGET exact-TRISIO predicate removed: parked-spare GP4 direction corruption evades the remaining required-subset check"
"src/bypass_mcu_pic12f675.c	s@wpu_latches == (uint8_t)(1U << FOOTSW_PIN)@0U != (wpu_latches \& (uint8_t)(1U << FOOTSW_PIN))@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:WPU.GP0	TARGET exact WPU guard weakened to GP5-present only; extra output-pin pull-up latches go undetected"
"src/bypass_mcu_pic12f675.c	s@ansel   = (uint8_t)(ANSEL & ANSEL_OUTPUT_MASK);@ansel   = (uint8_t)(ANSEL \& 0x07U);@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:ANSEL.ANS3	TARGET ANSEL guard narrowed to ANS0..ANS2, dropping ANS3; GP4 re-selected analog goes undetected (GPIO bit 4 maps to ANSEL bit 3, so this is the mapping's own mutant)"
"src/bypass_mcu_pic12f675.c	s@(CMCON_COMPARATOR_OFF == cmcon)  &&@(1U != 0U)  \&\&@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:CMCON.CM0	TARGET comparator-off guard defeated; a CMCON upset re-takes GP0..GP2 with no reset (no PIC10F322 counterpart -- that part has no comparator)"
"src/bypass_mcu_pic12f675.c	s@(OPTION_REG_CONFIG    == option) &&@((OPTION_REG_CONFIG \& 0xAFU) == (option \& 0xAFU)) \&\&@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:OPTION.INTEDG	TARGET exact OPTION_REG comparison weakened to ignore INTEDG and T0SE; both otherwise-silent bit upsets stop forcing reset while PS remains guarded"
"src/bypass_mcu_pic12f675.c	s@(0U                   == adon)   &&@((0U == adon) || (0U != adon)) \&\&@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:ADCON0.ADON	TARGET ADC-on guard tautologized while retaining the volatile-derived operand; an ADON upset no longer forces reset"
"src/bypass_mcu_pic12f675.c	s@(OPTION_REG_CONFIG    == option) &&@((OPTION_REG_CONFIG \& 0x7FU) == (option \& 0x7FU)) \&\&@;s@(0U == wpu_global);@((0U == wpu_global) || (0U != wpu_global));@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:OPTION.nGPPU	TARGET global pull-up enable detection defeated in both its exact OPTION_REG and dedicated nGPPU checks; the isolated nGPPU injection no longer forces reset"
"src/bypass_mcu_pic12f675.c	s@(osccal_snapshot_     == osccal);@(1U != 0U);@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:OSCCAL.CAL0	TARGET oscillator-trim guard defeated; a corrupt OSCCAL never forces a reset (no PIC10F322 counterpart -- that part compares OSCCON against a constant)"
"src/bypass_mcu_pic12f675.c	s@        next_ctx.program_state = res.program_state;@        (void)res.program_state; /* MUTANT: program-state write-back dropped */@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	lockstep:divergence	TARGET program_state write-back dropped: the context never enters release lockout and lock-step diverges from the pure model"
"src/bypass_mcu_pic12f675.c	s@        next_ctx.effect_state  = res.effect_state;@@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	lockstep:divergence	TARGET effect_state write-back dropped: the pins still follow res, so only the ctx_ lock-step against the pure model diverges"
"src/bypass_mcu_pic12f675.c	s@            next_ctx.debounce_counter = res.lockout_value;@            (void)res.lockout_value; /* MUTANT: lockout reload dropped */@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	lockstep:divergence	TARGET debounce lockout write-back dropped: the context retains its integrated threshold instead of RELEASE_THRESH and lock-step diverges"
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target	resync:minimum-pulse	TARGET relay coil pulse shortened below the datasheet minimum; the fail-safe recovery actuation is then too short to resynchronize the relay, so the fault lane reports it before the target-I/O minimum check gets to run"
"src/bypass_mcu_pic12f675.c	s@static void hw_wdt_pet(void) { CLRWDT(); }@static void hw_wdt_pet(void) { (void)0; /* MUTANT: no WDT pet */ }@	PIC12F675_SOAK_VARIANT=cd4053_simple PIC12F675_SOAK_DURATION_MS=$PIC_SOAK_MUT_MS PIC12F675_SOAK_LIVENESS_INTERVAL_MS=$PIC_SOAK_MUT_LIVENESS_MS PIC12F675_SOAK_COMBINATION_NAME=mutation-wdt pic12f675-test-soak	soak:wdt-reset	SOAK main-loop WDT pet removed; the soak's reset notifier catches the un-pet watchdog inside the short mutation window (this part's period is ~288 ms, well inside it)"
# F2 context-SEU: delete the polled shadow clause; killed by the fault leg.
"src/bypass_mcu_pic12f675.c	s@(ctx_check_ != debounce_ctx_check_word(next_ctx)) ||@(0U != 0U) ||@	PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target	fault:ctx.debounce.inrange	PIC12F675 F2 shadow clause deleted from the polled sanity gate; the in-range debounce SEU is no longer caught and the target fault leg ctx.debounce.inrange case sees 0 resets at checks=38."
)

# --- AVR-XT shell mutants (src/bypass_mcu_avr_xt.c) ---------------------------
# The ATtiny202 counterpart of the classic-AVR shell mutants above and the PIC
# ones below them. Every entry is killed by driving the REAL avr-gcc-built image
# in yasimavr, so the whole lane is gated on the ATtiny_DFP and the patched venv
# both being present AND the unmutated tree passing each kill target (probe
# below): every attiny202-* target exits 0 when an input is missing, which
# without the gate would read as a lane full of survivors.
#
# Kill targets are chosen for what each fault actually perturbs, not for
# convenience -- an inverted LED shows up in the functional trace, a defeated
# SFR guard only in fault injection, a dropped state write-back only in
# lock-step, a missing WDT pet only in the soak, and a shortened coil pulse only
# in the disassembly oracle. Where one variant suffices the entry pins it with
# XT_SIM_VARIANT so the mutant does not pay for all three.
#
# Each entry: file<TAB>sed-expression<TAB>make-args<TAB>description.
XT_MUTATIONS=(
"src/bypass_mcu_avr_xt.c	s@hw_outputs_reassert_safe();@@	XT_SIM_VARIANT=tq2_l2_5v_relay attiny202-fault	latch clear removed from the emergency helper; the physical RESYNC oracle sees PA2/PA3 or their register state remain unsafe at the reset spin"
"src/bypass_mcu_avr_xt.c	/static void hw_emergency_outputs_quiesce/,/^}/s@#if defined(TQ2_L2_5V_RELAY)@#if 0 /* MUTANT: latch-only emergency path */@	XT_SIM_VARIANT=tq2_l2_5v_relay attiny202-fault	emergency path reduced to the ordinary OUT-latch clear; coil-pin INVEN leaves physical PA2/PA3 high at the reset spin"
"src/bypass_output_tq2_l2_5v_relay.c	/void hw_outputs_reassert_safe/,/^}/s@    set_relay_coils_low();@@	XT_SIM_VARIANT=tq2_l2_5v_relay attiny202-fault	relay coil-clear removed from hw_outputs_reassert_safe (the op becomes a no-op); the CORRECT fault mechanism sees the coil stay energized and reset"
# -- observable behaviour: killed by the functional + output-trace driver ------
"src/bypass_mcu_avr_xt.c	s@void hw_led_pin_set_high(void) { PORTA.OUTSET = (uint8_t)(1U << LED_PIN); }@void hw_led_pin_set_high(void) { PORTA.OUTCLR = (uint8_t)(1U << LED_PIN); }@	XT_SIM_VARIANT=cd4053_simple attiny202-sim	XT set_engaged LED inverted (OUTSET becomes OUTCLR; PA1 never lights); toggle assertions catch it"
"src/bypass_mcu_avr_xt.c	s@void hw_led_pin_set_low(void)  { PORTA.OUTCLR = (uint8_t)(1U << LED_PIN); }@void hw_led_pin_set_low(void)  { PORTA.OUTSET = (uint8_t)(1U << LED_PIN); }@	XT_SIM_VARIANT=cd4053_simple attiny202-sim	XT set_bypass LED clear inverted (PA1 stuck lit); boot-dark and alternating-toggle checks catch it"
"src/bypass_mcu_avr_xt.c	s@(0U == (PORTA.IN & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA.IN \& (uint8_t)(1U << FOOTSW_PIN)))@	XT_SIM_VARIANT=cd4053_simple attiny202-sim	XT footswitch read polarity inverted (PA7 sense flipped -> toggles on release, not press)"
"src/bypass_mcu_avr_xt.c	s@void hw_pin_set_high(uint8_t const pin) { PORTA.OUTSET = (uint8_t)(1U << pin); }@void hw_pin_set_high(uint8_t const pin) { PORTA.OUTCLR = (uint8_t)(1U << pin); }@	XT_SIM_VARIANT=tq2_l2_5v_relay attiny202-sim	XT control-pin drive inverted (coil/CTL bit never set); PA2/PA3 transition trace catches it"
"src/bypass_mcu_avr_xt.c	s@    PORTA.OUTCLR = output_mask; // selected outputs -> low latch@    PORTA.OUTSET = output_mask; // MUTANT: outputs latched HIGH before DIR@	XT_SIM_VARIANT=tq2_l2_5v_relay attiny202-sim	XT output pins latched high before the DIR write (glitch: both relay coils driven at startup); startup trace catches the unsafe pre-config high"
# -- internal trajectory: killed by the ctx_-vs-model lock-step co-simulation --
"src/bypass_mcu_avr_xt.c	s@next_ctx.debounce_counter = res.lockout_value;@(void)0; /* MUTANT: lockout reload dropped */@	XT_SIM_VARIANT=cd4053_simple attiny202-lockstep	XT anti-retrigger lockout reload dropped; counter keeps its integrated value instead of RELEASE_THRESH"
"src/bypass_mcu_avr_xt.c	s@next_ctx.program_state = res.program_state;@(void)0; /* MUTANT: program_state write-back dropped */@	XT_SIM_VARIANT=cd4053_simple attiny202-lockstep	XT program_state write-back dropped; the state machine never advances out of PRESS_DEBOUNCE_WAIT"
"src/bypass_mcu_avr_xt.c	s@next_ctx.effect_state  = res.effect_state;@(void)0; /* MUTANT: effect_state write-back dropped */@	XT_SIM_VARIANT=cd4053_simple attiny202-lockstep	XT effect_state write-back dropped; ctx_ diverges from the model even where the LED briefly agrees"
# -- guards: killed by fault injection into the running image ------------------
"src/bypass_mcu_avr_xt.c	s@if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@if ( 0 \&\& (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT per-tick sanity gate disabled wholesale; no corruption ever forces the reset path"
"src/bypass_mcu_avr_xt.c	s@(actual_direction_mask == (uint8_t)BYPASS_OUTPUT_DDR_MASK) &&@(1U != 0U) \&\&@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT exact PORTA.DIR predicate removed; a footswitch pin turned output (or a spare turned input) evades the required-subset check"
"src/bypass_mcu_avr_xt.c	s@(uint8_t)(PORTA.OUT & (uint8_t)BYPASS_OUTPUT_DDR_MASK)@(uint8_t)(PORTA.OUT \& (uint8_t)0x0EU)@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT output-latch mask omits spare PA6; an unexpected high latch there goes undetected"
"src/bypass_mcu_avr_xt.c	s@((uint8_t)WDT_LOCK_bm  == wdt_locked)  &&@(1U != 0U) \&\&@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT WDT hardware-lock guard defeated; an unlocked watchdog never forces reset"
"src/bypass_mcu_avr_xt.c	s@((uint16_t)TCB0_CCMP_1MS == tcb0_ccmp) ;@(1U != 0U) ;@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT tick-period (TCB0.CCMP) guard defeated; a corrupt 1 ms reload never forces reset"
"src/bypass_mcu_avr_xt.c	s@return (PORTA.PIN7CTRL == (uint8_t)PORT_PULLUPEN_bm);@return 1U;@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT footswitch pin-control guard defeated; a cleared PA7 PULLUPEN (floating input) never forces reset"
# Not a defeated guard but a WEAKENED one: this is the exact pre-hardening
# predicate, so it still catches a cleared pull-up and only stops catching
# INVEN. It is the mutant that proves the fault matrix's PIN7CTRL=0x88 case is
# load-bearing -- 0x88 keeps PULLUPEN set, so the bit test below is satisfied
# and only the exact comparison can reject it.
"src/bypass_mcu_avr_xt.c	s@return (PORTA.PIN7CTRL == (uint8_t)PORT_PULLUPEN_bm);@return (PORTA.PIN7CTRL \& (uint8_t)PORT_PULLUPEN_bm) != 0U;@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT footswitch pin-control guard weakened to a PULLUPEN bit test; an INVEN upset preserving the pull-up reverses the active-low PA7 sense undetected"
# -- liveness: killed by the soak's reset witness ------------------------------
"src/bypass_mcu_avr_xt.c	s@            hw_wdt_pet();@            (void)0; /* MUTANT: no WDT pet */@	XT_SIM_VARIANT=cd4053_simple XT_SOAK_DURATION_MS=$XT_SOAK_MUT_MS XT_SOAK_LIVENESS_INTERVAL_MS=$XT_SOAK_MUT_MS XT_SOAK_PROGRESS_INTERVAL_MS=$XT_SOAK_MUT_MS attiny202-soak	XT main-loop WDT pet removed; the soak's GPR0 reset witness trips within one ~256 ms WDT period"
"src/bypass_mcu_avr_xt.c	s@    timer_isr_called_ = TIMER_ISR_CALLED;@    timer_isr_called_ = TIMER_ISR_NOT_CALLED;@	XT_SIM_VARIANT=cd4053_simple XT_SOAK_DURATION_MS=$XT_SOAK_MUT_MS XT_SOAK_LIVENESS_INTERVAL_MS=$XT_SOAK_MUT_MS XT_SOAK_PROGRESS_INTERVAL_MS=$XT_SOAK_MUT_MS attiny202-soak	XT ISR/main liveness handshake broken (ISR clears its own flag); main never pets, so the WDT resets"
# -- absolute pulse width: killed by the disassembly oracle --------------------
# These two live in the SHARED output drivers rather than the XT shell. The PIC
# lane mutates the same lines against its own cycle-exact target I/O check; here
# they gate the AVR-XT's only route to an absolute width -- the _delay_ms loop
# read back out of the built image -- which is where the width lives because it
# is a compile-time property, and because the yasimavr harness cannot measure a
# busy-wait pulse while its one-cycle sampling trips the upstream SimLoop.run()
# defect (see test/avr/test_attiny202_delay_oracle.py).
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	attiny202-delay-oracle	XT relay coil pulse shortened below the 4 ms datasheet minimum; the image's _delay_ms loop no longer matches the 12 ms design"
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	attiny202-delay-oracle	XT cd4053_with_mute pre-switch mute window shortened from 5 ms; the disassembled delay loop no longer matches the design"
# -- F2 context-SEU: killed by fault injection into the running image -----------
"src/bypass_mcu_avr_xt.c	s@                next_ctx.debounce_counter);@                ctx_.debounce_counter); /* MUTANT: consume live persisted SRAM */@	XT_SIM_VARIANT=cd4053_simple attiny202-fault	XT F2 ISR transaction defeated after validation: integration consumes live ctx_ instead of the validated snapshot. The one-shot transaction case then observes a phantom transition instead of a safe overwrite."
)

# Combined work list, filled in mutant order (core/AVR first, then any enabled
# PIC subsets, then the ATtiny202 lane). Each element packs:
# category<US>kind<US>arg<US>file<US>sed<US>desc,
# where <US> is the ASCII unit-separator (\x1f). A NON-whitespace separator is
# required: the `arg` field is empty for the PIC gpsim/soak kinds, and `read`
# with an IFS-whitespace delimiter (space/tab/newline) COLLAPSES the adjacent
# delimiters around an empty field, shifting every later field left. \x1f cannot
# appear in a sed expression or description, so the pack/unpack is lossless.
# `category` is a display label used only to group the ordered replay of results;
# the whole list is dispatched through one bounded-parallel pool below.
US=$'\x1f'
job_specs=()

declare -A mutation_inventory_seen=()
validate_mutation_inventory() {
    local array_name=$1 label=$2 expected=$3 field_count=$4 i entry key
    local -n entries=$array_name
    mutation_require_count "$label" "$expected" "${#entries[@]}" || return 1
    for i in "${!entries[@]}"; do
        entry=${entries[i]}
        mutation_parse_record "$label[$i]" "$field_count" "$entry" || return 1
        key=$entry
        if [[ -n ${mutation_inventory_seen["$key"]+x} ]]; then
            printf 'ERROR: duplicate mutation inventory record in %s[%d]\n' \
                "$label" "$i" >&2
            return 1
        fi
        mutation_inventory_seen["$key"]=1
    done
}

validate_mutation_inventory MUTATIONS core/AVR "$MUTATION_EXPECTED_CORE" 4 || exit 2
validate_mutation_inventory PIC_GPSIM_MUTATIONS PIC-gpsim \
    "$MUTATION_EXPECTED_PIC_GPSIM" 3 || exit 2
validate_mutation_inventory PIC_TARGET_MUTATIONS PIC-target \
    "$MUTATION_EXPECTED_PIC_TARGET" 4 || exit 2
validate_mutation_inventory PIC_SOAK_MUTATIONS PIC-soak \
    "$MUTATION_EXPECTED_PIC_SOAK" 3 || exit 2
validate_mutation_inventory PIC10F320_HOST_MUTATIONS PIC10F320-host \
    "$MUTATION_EXPECTED_PIC320_HOST" 4 || exit 2
validate_mutation_inventory PIC10F320_TOOL_MUTATIONS PIC10F320-tool \
    "$MUTATION_EXPECTED_PIC320_TOOL" 4 || exit 2
validate_mutation_inventory PIC12F675_MUTATIONS PIC12F675 \
    "$MUTATION_EXPECTED_PIC12F675" 5 || exit 2
validate_mutation_inventory XT_MUTATIONS ATtiny202 "$MUTATION_EXPECTED_XT" 4 || exit 2
inventory_total=$((${#MUTATIONS[@]} + ${#XT_MUTATIONS[@]} \
    + ${#PIC_GPSIM_MUTATIONS[@]} \
    + ${#PIC_TARGET_MUTATIONS[@]} + ${#PIC_SOAK_MUTATIONS[@]} \
    + ${#PIC10F320_HOST_MUTATIONS[@]} + ${#PIC10F320_TOOL_MUTATIONS[@]} \
    + ${#PIC12F675_MUTATIONS[@]}))
mutation_require_count total "$MUTATION_EXPECTED_TOTAL" "$inventory_total" || exit 2

# F2 exclusion invariant: PIC10F320 is capacity-excluded from the context-SEU
# check (256-word flash; see Makefile BYPASS_CTX_CHECK_FLAG, NOT added to
# PIC10F320_CFLAGS). Its shell must therefore reference NEITHER the pure fold
# nor the opt-in macro -- which is why the four F2 mutants above have no
# PIC10F320 counterpart and could not be built there even in principle. Assert
# that statically on every run (real and --sandbox self-test) so a future edit
# that wires F2 into the 320 shell fails loudly here.
pic10f320_f2_shell="$PROJ_DIR/src/bypass_mcu_pic10f320.c"
if [ ! -f "$pic10f320_f2_shell" ]; then
    echo "ERROR: PIC10F320 shell not found for the F2-exclusion assertion: $pic10f320_f2_shell" >&2
    exit 2
fi
if pic10f320_f2_hits=$(grep -nE 'debounce_ctx_check_word|BYPASS_CTX_CHECK' "$pic10f320_f2_shell"); then
    echo "ERROR: PIC10F320 is F2-EXCLUDED but its shell references the context-check" >&2
    echo "       machinery (BYPASS_CTX_CHECK / debounce_ctx_check_word):" >&2
    printf '%s\n' "$pic10f320_f2_hits" >&2
    exit 2
fi

collect_baseline_targets() {
    local array_name=$1 label=$2 field_count=$3 target_index=$4 output_name=$5
    local entry target
    local -n entries=$array_name output=$output_name
    local -A seen=()
    output=()
    for entry in "${entries[@]}"; do
        mutation_parse_record "$label baseline" "$field_count" "$entry" || return 1
        target=${MUTATION_RECORD_FIELDS[target_index]}
        case "$target" in
            host:*'|'*) target=${target#*|} ;;
        esac
        split_mutation_make_command "$label baseline" "$target" || return 1
        if [[ -z ${seen["$target"]+x} ]]; then
            seen["$target"]=1
            output+=("$target")
        fi
    done
}

CORE_BASE_TARGETS=()
PIC10F320_HOST_BASE_TARGETS=()
PIC10F320_BASE_TARGETS=()
PIC12F675_BASE_TARGETS=()
collect_baseline_targets MUTATIONS core/AVR 4 2 CORE_BASE_TARGETS || exit 2
collect_baseline_targets PIC10F320_HOST_MUTATIONS PIC10F320-host 4 2 \
    PIC10F320_HOST_BASE_TARGETS || exit 2
collect_baseline_targets PIC10F320_TOOL_MUTATIONS PIC10F320-tool 4 2 \
    PIC10F320_BASE_TARGETS || exit 2
collect_baseline_targets PIC12F675_MUTATIONS PIC12F675 5 2 \
    PIC12F675_BASE_TARGETS || exit 2

HOST_BASE_TARGETS=()
declare -A host_baseline_seen=()
for target in "${CORE_BASE_TARGETS[@]}" "${PIC10F320_HOST_BASE_TARGETS[@]}"; do
    if [[ -z ${host_baseline_seen["$target"]+x} ]]; then
        host_baseline_seen["$target"]=1
        HOST_BASE_TARGETS+=("$target")
    fi
done

if [ "$SANDBOX_SELFTEST_DONE" -eq 1 ]; then
    [[ $RESULT_DIR == /* ]] || {
        echo "ERROR: mutation result root is not absolute: $RESULT_DIR" >&2
        exit 1
    }
    # Fully provisioned, then three partial shapes: every optional simulator
    # absent (only the host mutants dispatch), ATtiny202 alone absent, and the
    # eighth category (PIC12F675) alone absent. These conservation cases are
    # derived from the category pins so a new category cannot leave an old total
    # looking authoritative.
    always_dispatched=$((MUTATION_EXPECTED_CORE + MUTATION_EXPECTED_PIC320_HOST))
    optional_mutants=$((MUTATION_EXPECTED_TOTAL - always_dispatched))
    without_xt=$((MUTATION_EXPECTED_TOTAL - MUTATION_EXPECTED_XT))
    without_pic12f675=$((MUTATION_EXPECTED_TOTAL - MUTATION_EXPECTED_PIC12F675))
    mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" \
        "$MUTATION_EXPECTED_TOTAL" 0 "$MUTATION_EXPECTED_TOTAL" 0 0 0 0 || exit 1
    mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" "$always_dispatched" \
        "$optional_mutants" "$always_dispatched" 0 0 0 0 || exit 1
    mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" "$without_xt" \
        "$MUTATION_EXPECTED_XT" "$without_xt" 0 0 0 0 || exit 1
    mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" "$without_pic12f675" \
        "$MUTATION_EXPECTED_PIC12F675" "$without_pic12f675" 0 0 0 0 || exit 1
    if mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" \
            "$((always_dispatched - 1))" "$optional_mutants" \
            "$((always_dispatched - 1))" 0 0 0 0 >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted a dropped dispatch" >&2; exit 1
    fi
    if mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" "$always_dispatched" \
            "$optional_mutants" "$((always_dispatched - 1))" 0 0 0 0 \
            >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted a missing result" >&2; exit 1
    fi
    if mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" "$always_dispatched" \
            "$optional_mutants" "$always_dispatched" 0 0 1 0 \
            >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted a failed worker" >&2; exit 1
    fi
    # Pin the public timeout grammar, including the distinction between unset
    # (default 900) and explicitly empty (invalid).
    resolved_timeout=$(unset MUTATION_TIMEOUT_S; resolve_mutation_timeout) || exit 1
    [ "$resolved_timeout" = 900 ] || {
        echo "ERROR: unset MUTATION_TIMEOUT_S did not resolve to 900" >&2; exit 1
    }
    for timeout_control in 1 0.001 0.5 00.5 86400; do
        resolved_timeout=$(MUTATION_TIMEOUT_S="$timeout_control" resolve_mutation_timeout) \
            || exit 1
        [ "$resolved_timeout" = "$timeout_control" ] || {
            echo "ERROR: valid MUTATION_TIMEOUT_S changed during validation: $timeout_control" >&2
            exit 1
        }
    done
    for timeout_control in '' 0 00.000 -1 malformed .5 1. 1e2 0.0001 86400.001; do
        if timeout_diagnostic=$(MUTATION_TIMEOUT_S="$timeout_control" \
                resolve_mutation_timeout 2>&1); then
            echo "ERROR: invalid MUTATION_TIMEOUT_S was accepted: '$timeout_control'" >&2
            exit 1
        fi
        [[ $timeout_diagnostic == *'must be 0.001..86400 seconds'* ]] || {
            echo "ERROR: invalid MUTATION_TIMEOUT_S had the wrong diagnostic: $timeout_diagnostic" >&2
            exit 1
        }
    done
    # 124 is timeout(1) expiry and is the one that must not regress: if it ever
    # stops counting as infrastructure, a hung mutant is recorded as KILLED and
    # the suite reports a clean run it never actually completed.
    for checker_rc in 124 125 126 127 143; do
        mutation_checker_status_is_infrastructure_error "$checker_rc" || {
            echo "ERROR: mutation accounting accepted checker infrastructure status $checker_rc" >&2
            exit 1
        }
    done
    # The bound is real, and it reports as infrastructure rather than as a kill.
    # Asserting the classifier alone would pass even if mutation_bounded were
    # deleted, so drive the actual wrapper against a command that outlives it.
    mutation_selftest_rc=0
    MUTATION_TIMEOUT_S=0.1 mutation_bounded sleep 30 >/dev/null 2>&1 || mutation_selftest_rc=$?
    [ "$mutation_selftest_rc" -eq 124 ] || {
        echo "ERROR: mutation_bounded did not report timeout expiry as 124 (got $mutation_selftest_rc)" >&2
        exit 1
    }
    mutation_checker_status_is_infrastructure_error "$mutation_selftest_rc" || {
        echo "ERROR: mutation_bounded expiry is not classified as infrastructure" >&2
        exit 1
    }
    # ...and does not fire on a command that finishes inside it, so the bound
    # cannot pass by simply failing everything.
    MUTATION_TIMEOUT_S=1 mutation_bounded true >/dev/null 2>&1 || {
        echo "ERROR: mutation_bounded failed a command that completed in time" >&2
        exit 1
    }
    MUTATION_TIMEOUT_S=1 mutation_bounded bash -c 'sleep 0.02 &' \
        >/dev/null 2>&1 || {
        echo "ERROR: mutation_bounded failed to clean a short-lived descendant" >&2
        exit 1
    }
    fake_setsid_dir="$RESULT_DIR/fake-setsid-bin"
    mkdir "$fake_setsid_dir"
    cat > "$fake_setsid_dir/setsid" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod 750 "$fake_setsid_dir/setsid"
    setsid_failure_rc=0
    PATH="$fake_setsid_dir:$PATH" MUTATION_TIMEOUT_S=1 \
        mutation_bounded true >/dev/null 2>&1 || setsid_failure_rc=$?
    [ "$setsid_failure_rc" -eq 125 ] || {
        echo "ERROR: setsid launch failure was not classified as infrastructure (got $setsid_failure_rc)" >&2
        exit 1
    }
    # A nested wrapper deadline may fire before the outer bound and then be
    # collapsed by Make to an ordinary status. Its out-of-band marker must still
    # force infrastructure status 125 rather than crediting a mutation kill.
    nested_timeout_rc=0
    MUTATION_TIMEOUT_S=1 mutation_bounded bash -c '
        timeout -s KILL 0.1 sleep 30 && exit 91
        rc=$?
        [ "$rc" -ne 137 ] || : > "$MUTATION_INFRA_MARKER"
        exit 1
    ' \
        >/dev/null 2>&1 || nested_timeout_rc=$?
    [ "$nested_timeout_rc" -eq 125 ] || {
        echo "ERROR: nested checker timeout was not classified as infrastructure (got $nested_timeout_rc)" >&2
        exit 1
    }

    # Interrupt a runner while a bounded checker owns a nested timeout group and
    # a TERM-ignoring descendant. The configured 30-second bound is deliberately
    # much longer than this test: disappearance must come from signal cleanup.
    interrupt_dir="$RESULT_DIR/interrupt"
    interrupt_result="$interrupt_dir/result"
    interrupt_checker="$interrupt_dir/checker"
    interrupt_ignore="$interrupt_dir/ignore-term"
    mkdir -p "$interrupt_result"
    cat > "$interrupt_ignore" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
printf '%s\n' "$BASHPID" > "${MUTATION_INTERRUPT_IGNORE_PID:?}"
while :; do sleep 1; done
EOF
    cat > "$interrupt_checker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$BASHPID" > "${MUTATION_INTERRUPT_CHECKER_PID:?}"
timeout 30 "${MUTATION_INTERRUPT_IGNORE:?}" &
printf '%s\n' "$!" > "${MUTATION_INTERRUPT_NESTED_PID:?}"
for ((attempt = 0; attempt < 500; attempt++)); do
    [ -s "${MUTATION_INTERRUPT_IGNORE_PID:?}" ] && break
    sleep 0.01
done
[ -s "${MUTATION_INTERRUPT_IGNORE_PID:?}" ] || exit 92
: > "${MUTATION_INTERRUPT_READY:?}"
wait
EOF
    chmod 750 "$interrupt_checker" "$interrupt_ignore"
    interrupt_ready="$interrupt_dir/ready"
    interrupt_checker_pid_file="$interrupt_dir/checker.pid"
    interrupt_nested_pid_file="$interrupt_dir/nested.pid"
    interrupt_ignore_pid_file="$interrupt_dir/ignore.pid"
    (
        RESULT_DIR="$interrupt_result"
        MUTATION_STOP_FILE="$interrupt_result/stopping"
        active_pids=()
        launching_pid=0
        launching_checker_pid=0
        set +m
        trap cleanup_mutation_run EXIT
        trap 'mutation_signal_exit 129' HUP
        trap 'mutation_signal_exit 130' INT
        trap 'mutation_signal_exit 143' TERM
        MUTATION_TIMEOUT_S=30 \
            MUTATION_INTERRUPT_CHECKER_PID="$interrupt_checker_pid_file" \
            MUTATION_INTERRUPT_NESTED_PID="$interrupt_nested_pid_file" \
            MUTATION_INTERRUPT_IGNORE_PID="$interrupt_ignore_pid_file" \
            MUTATION_INTERRUPT_READY="$interrupt_ready" \
            MUTATION_INTERRUPT_IGNORE="$interrupt_ignore" \
            mutation_bounded "$interrupt_checker"
    ) &
    interrupt_runner_pid=$!
    for ((interrupt_attempt = 0; interrupt_attempt < 500; interrupt_attempt++)); do
        [ -f "$interrupt_ready" ] && break
        kill -0 "$interrupt_runner_pid" 2>/dev/null || break
        sleep 0.01
    done
    interrupt_error=
    if [ ! -f "$interrupt_ready" ]; then
        interrupt_error="interruption fixture did not become ready"
    else
        interrupt_checker_pid=$(<"$interrupt_checker_pid_file")
        interrupt_nested_pid=$(<"$interrupt_nested_pid_file")
        interrupt_ignore_pid=$(<"$interrupt_ignore_pid_file")
        shopt -s nullglob
        interrupt_slots=("$interrupt_result"/checker-session.*)
        shopt -u nullglob
        [ "${#interrupt_slots[@]}" -eq 1 ] \
            && read -r interrupt_registered_sid interrupt_checker_token \
                < "${interrupt_slots[0]}" \
            || interrupt_error="interruption fixture did not publish exactly one checker session"
        read -r interrupt_checker_pgid interrupt_checker_sid \
            < <(ps -o pgid=,sid= -p "$interrupt_checker_pid")
        read -r interrupt_nested_pgid interrupt_nested_sid \
            < <(ps -o pgid=,sid= -p "$interrupt_nested_pid")
        read -r interrupt_ignore_pgid interrupt_ignore_sid \
            < <(ps -o pgid=,sid= -p "$interrupt_ignore_pid")
        if [ "${interrupt_registered_sid:-}" != "$interrupt_checker_sid" ] \
                || [ "$interrupt_checker_pgid" != "$interrupt_checker_sid" ] \
                || [ "$interrupt_nested_pgid" != "$interrupt_nested_pid" ] \
                || [ "$interrupt_nested_pgid" = "$interrupt_checker_pgid" ] \
                || [ "$interrupt_nested_sid" != "$interrupt_checker_sid" ] \
                || [ "$interrupt_ignore_pgid" != "$interrupt_nested_pgid" ] \
                || [ "$interrupt_ignore_sid" != "$interrupt_checker_sid" ]; then
            interrupt_error="interruption fixture did not create nested checker process groups in one session"
        fi
    fi

    kill -TERM "$interrupt_runner_pid" 2>/dev/null || true
    if wait "$interrupt_runner_pid"; then interrupt_runner_rc=0; else interrupt_runner_rc=$?; fi
    [ "$interrupt_runner_rc" -eq 143 ] \
        || interrupt_error="${interrupt_error:+$interrupt_error; }interrupted runner exited $interrupt_runner_rc, expected 143"

    if [ -n "${interrupt_checker_sid:-}" ]; then
        for ((interrupt_attempt = 0; interrupt_attempt < 100; interrupt_attempt++)); do
            interrupt_alive=0
            for interrupt_pid in "$interrupt_checker_pid" "$interrupt_nested_pid" "$interrupt_ignore_pid"; do
                if kill -0 "$interrupt_pid" 2>/dev/null; then interrupt_alive=1; break; fi
            done
            mutation_session_has_processes "$interrupt_checker_sid"
            interrupt_session_state=$?
            if [ "$interrupt_alive" -eq 0 ] && [ "$interrupt_session_state" -eq 1 ]; then
                break
            fi
            [ "$interrupt_session_state" -ne 2 ] \
                || interrupt_error="${interrupt_error:+$interrupt_error; }process snapshot failed during interruption proof"
            sleep 0.05
        done
        mutation_session_has_processes "$interrupt_checker_sid"
        interrupt_session_state=$?
        if [ "$interrupt_alive" -ne 0 ] || [ "$interrupt_session_state" -ne 1 ]; then
            interrupt_error="${interrupt_error:+$interrupt_error; }checker descendants survived interrupted-run cleanup"
            mutation_signal_session_groups "$interrupt_checker_sid" \
                "${interrupt_checker_token:-invalid}" KILL || true
        fi
    fi
    [ -z "$interrupt_error" ] || { echo "ERROR: $interrupt_error" >&2; exit 1; }

    # Exercise worker ownership independently of checker registration. TERM
    # removes the tracked worker from Bash's job table while its stopped,
    # TERM-ignoring child remains in that PGID; only the inherited worker token
    # can safely retain and KILL the group afterward.
    job_gap_result="$RESULT_DIR/job-gap-result"
    job_gap_pid_file="$RESULT_DIR/job-gap.pid"
    job_gap_ready="$RESULT_DIR/job-gap.ready"
    job_gap_runner_log="$RESULT_DIR/job-gap.stderr"
    job_gap_token="job-gap-$RANDOM-$BASHPID"
    job_gap_worker_token="mutation-worker.$RANDOM$RANDOM"
    job_gap_worker_slot="$job_gap_result/$job_gap_worker_token"
    job_gap_worker="$RESULT_DIR/job-gap-worker"
    mkdir -p "$job_gap_result"
    cat > "$job_gap_worker" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$BASHPID" "${MUTATION_WORKER_TOKEN:?}" \
    > "${MUTATION_WORKER_SLOT:?}"
"${MUTATION_INTERRUPT_IGNORE:?}" &
wait
EOF
    chmod 750 "$job_gap_worker"
    printf '0 %s\n' "$job_gap_worker_token" > "$job_gap_worker_slot"
    (
        RESULT_DIR="$job_gap_result"
        MUTATION_STOP_FILE="$job_gap_result/stopping"
        active_pids=()
        launching_pid=0
        launching_checker_pid=0
        set +m
        trap cleanup_mutation_run EXIT
        trap 'mutation_signal_exit 143' TERM
        MUTATION_WORKER_TOKEN="$job_gap_worker_token" \
            MUTATION_WORKER_SLOT="$job_gap_worker_slot" \
            MUTATION_JOB_GAP_TOKEN="$job_gap_token" \
            MUTATION_INTERRUPT_IGNORE_PID="$job_gap_pid_file" \
            MUTATION_INTERRUPT_IGNORE="$interrupt_ignore" \
            setsid "$job_gap_worker" >/dev/null 2>&1 &
        for ((attempt = 0; attempt < 500; attempt++)); do
            [ -s "$job_gap_pid_file" ] && break
            sleep 0.01
        done
        [ -s "$job_gap_pid_file" ] || exit 93
        : > "$job_gap_ready"
        wait
    ) 2>"$job_gap_runner_log" &
    job_gap_runner_pid=$!
    for ((interrupt_attempt = 0; interrupt_attempt < 500; interrupt_attempt++)); do
        [ -f "$job_gap_ready" ] && break
        kill -0 "$job_gap_runner_pid" 2>/dev/null || break
        sleep 0.01
    done
    [ -f "$job_gap_ready" ] || {
        kill -TERM "$job_gap_runner_pid" 2>/dev/null || true
        wait "$job_gap_runner_pid" 2>/dev/null || true
        if [ -s "$job_gap_pid_file" ]; then
            job_gap_pid=$(<"$job_gap_pid_file")
            job_gap_pgid=$(ps -o pgid= -p "$job_gap_pid" 2>/dev/null || true)
            read -r job_gap_pgid <<< "$job_gap_pgid"
            if mutation_process_has_env_entry "$job_gap_pid" \
                    "MUTATION_JOB_GAP_TOKEN=$job_gap_token"; then
                kill -KILL -- "-$job_gap_pgid" 2>/dev/null || true
            fi
        fi
        echo "ERROR: worker launch-gap fixture did not become ready" >&2
        exit 1
    }
    job_gap_pid=$(<"$job_gap_pid_file")
    read -r job_gap_worker_pid published_worker_token < "$job_gap_worker_slot"
    job_gap_pgid=$(ps -o pgid= -p "$job_gap_pid")
    read -r job_gap_pgid <<< "$job_gap_pgid"
    if [ "$published_worker_token" != "$job_gap_worker_token" ] \
            || [ "$job_gap_pgid" != "$job_gap_worker_pid" ] \
            || [ "$job_gap_pid" = "$job_gap_worker_pid" ]; then
        if mutation_process_has_env_entry "$job_gap_pid" \
                "MUTATION_JOB_GAP_TOKEN=$job_gap_token"; then
            kill -KILL -- "-$job_gap_pgid" 2>/dev/null || true
        fi
        echo "ERROR: worker launch-gap fixture did not own a process group" >&2
        exit 1
    fi
    kill -STOP "$job_gap_pid"
    job_gap_state=$(ps -o stat= -p "$job_gap_pid")
    [[ $job_gap_state == T* ]] || {
        if mutation_process_has_env_entry "$job_gap_pid" \
                "MUTATION_JOB_GAP_TOKEN=$job_gap_token"; then
            kill -KILL -- "-$job_gap_pgid" 2>/dev/null || true
        fi
        echo "ERROR: worker launch-gap fixture did not enter stopped state" >&2
        exit 1
    }
    kill -TERM "$job_gap_runner_pid"
    if wait "$job_gap_runner_pid"; then job_gap_rc=0; else job_gap_rc=$?; fi
    [ "$job_gap_rc" -eq 143 ] || {
        if mutation_process_has_env_entry "$job_gap_pid" \
                "MUTATION_JOB_GAP_TOKEN=$job_gap_token"; then
            kill -KILL -- "-$job_gap_pgid" 2>/dev/null || true
        fi
        echo "ERROR: worker launch-gap runner exited $job_gap_rc, expected 143" >&2
        exit 1
    }
    for ((interrupt_attempt = 0; interrupt_attempt < 100; interrupt_attempt++)); do
        kill -0 "$job_gap_pid" 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 "$job_gap_pid" 2>/dev/null; then
        if mutation_process_has_env_entry "$job_gap_pid" \
                "MUTATION_JOB_GAP_TOKEN=$job_gap_token"; then
            kill -KILL -- "-$job_gap_pgid" 2>/dev/null || true
        fi
        echo "ERROR: unregistered worker survived current-shell job cleanup" >&2
        exit 1
    fi
    if mutation_checker_status_is_infrastructure_error 1; then
        echo "ERROR: mutation accounting rejected an ordinary mutation kill status" >&2
        exit 1
    fi
    signature_log="$RESULT_DIR/pic12-signature.log"
    write_pic12_gpsim_fixture() {
        local failing_assertion=${1-} failing_variant=${2-}
        local variant wrapper
        [ -z "$failing_assertion" ] || printf '  %s\n' "$failing_assertion"
        for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
            for wrapper in toggle power-on; do
                if [ "$variant" = "$failing_variant" ] && [ "$wrapper" = toggle ]; then
                    printf 'RESULT: 1 check(s) FAILED for /fixture/bypass-pic12f675-%s_simcal.hex\n' \
                        "$variant"
                else
                    printf 'RESULT: PASS (/fixture/bypass-pic12f675-%s_simcal.hex)\n' \
                        "$variant"
                fi
            done
        done
    }
    printf '%s\n' \
        '  inject ADCON0.ADON       @0x01f: 0x00 -> 0x01  (fixture)' \
        '    FAIL: 0 resets in 2000 ms (want exactly 1)  [gate did not fire?]' \
        'PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=cd4053_simple status=fail checks=38 failures=1' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 fault:ADCON0.ADON \
        'PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 named behavioral failure was not classified as killed" >&2
        exit 1
    }
    pic12f675_classify_checker_result 2 fault:OPTION.nGPPU \
        'PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: PIC12F675 wrong behavioral signature received kill credit" >&2
        exit 1
    }
    printf '%s\n' \
        '  inject relay coils    @0x005: 0x20 -> 0x22  (fixture, from BYPASS)' \
        '    FAIL: init=0x20 requested=0x22 read=0x22 injection=1 deenergized=0 deenergize-cycles=0 partial-clear=0 spin=1 GP1=0.000V GP2=5.000V GP4=0.000V resets=1 reset-coil-ms=11.312 set-coil-ms=0.000 final-gpio=0x20 clean=1' \
        'PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=fail checks=43 failures=1' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 resync:coil \
        'PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 resync:coil behavioral failure was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' \
        '    fixture: COUT and physical GP2 were HIGH before escalation; latch-only clear left GP2 at 5.000V' \
        '    FAIL: init=0x07 requested=0x06 read=0x46 injection=1 deenergized=0 deenergize-cycles=0 partial-clear=0 spin=1 GP1=0.000V GP2=5.000V GP4=0.000V resets=1 reset-coil-ms=11.312 set-coil-ms=0.000 final-gpio=0x20 clean=1' \
        'PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=fail checks=43 failures=1' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 resync:physical-coil \
        'PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 physical-coil behavioral failure was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'FAIL fixture: relay reassert from shadow coils 02 must clear both bits' \
        'FAIL fixture: relay reassert from shadow coils 04 must clear both bits' \
        'FAIL fixture: relay reassert from shadow coils 06 must clear both bits' \
        'PIC shipping-source coverage harness: 105 checks, 3 failures' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 host:atomic-clear \
        pic12f675-coverage-check-fw "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 host atomic-clear failure was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' \
        'cc: error: incidental diagnostic outside the completed host checker' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'FAIL fixture: relay reassert from shadow coils 02 must clear both bits' \
        'FAIL fixture: relay reassert from shadow coils 04 must clear both bits' \
        'FAIL fixture: relay reassert from shadow coils 06 must clear both bits' \
        'PIC shipping-source coverage harness: 105 checks, 3 failures' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 host:atomic-clear \
        pic12f675-coverage-check-fw "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: a complete PIC12F675 behavioral verdict lost to incidental compiler text" >&2
        exit 1
    }
    printf '%s\n' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'FAIL fixture: relay reassert from shadow coils 02 must clear both bits' \
        'FAIL fixture: relay reassert from shadow coils 04 must clear both bits' \
        'PIC shipping-source coverage harness: 105 checks, 3 failures' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 host:atomic-clear \
        pic12f675-coverage-check-fw "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: incomplete PIC12F675 host atomic-clear failure received kill credit" >&2
        exit 1
    }
    printf '%s\n' \
        '/fixture/bypass_mcu_pic12f675.c:194: error: compile fixture' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 host:atomic-clear \
        pic12f675-coverage-check-fw "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = compile-error ] \
        && [[ "$PIC12F675_CHECKER_DIAGNOSTIC" == *'compile fixture' ]] || {
        echo "ERROR: PIC12F675 host atomic-clear compile failure received kill credit" >&2
        exit 1
    }
    printf '%s\n' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'PIC shipping-source coverage harness: 105 checks, 0 failures' \
        'OK: all PIC shipping-source lines are covered except the documented reset path.' \
        'PIC12F675 coverage-oracle negative probe: PASS (source line 631)' \
        > "$signature_log"
    pic12f675_classify_checker_result 0 host:atomic-clear \
        pic12f675-coverage-check-fw "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = survived ] || {
        echo "ERROR: complete PIC12F675 host atomic-clear checker was not classified as survived" >&2
        exit 1
    }
    printf '%s\n' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'FAIL fixture: parked GP4 shadow (intent) fault must force the fail-safe reset with parked GP4 physically low before the spin (got r=1 gpio=10)' \
        'PIC shipping-source coverage harness: 105 checks, 1 failures' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 host:parked-output \
        pic12f675-coverage-check-fw "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 host parked-output failure was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'PIC shipping-source coverage harness: 86 checks, 0 failures' \
        'FAIL fixture: GP1 RESET-coil shadow fault must leave both coils de-energized before the reset spin' \
        'PIC shipping-source coverage harness: 105 checks, 1 failures' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 host:parked-output \
        pic12f675-coverage-check-fw "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: a non-GP4 host coverage failure received parked-output kill credit" >&2
        exit 1
    }
    write_pic12_gpsim_fixture \
        'FAIL: PRESS1_EARLY: LED (GP0) on too early, GPIO=0x3' \
        cd4053_simple > "$signature_log"
    pic12f675_classify_checker_result 1 gpsim:press-early \
        pic12f675-test-gpsim "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 gpsim behavioral signature was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' \
        '  FAIL: PRESS1_EARLY: LED (GP0) on too early, GPIO=0x3' \
        'RESULT: 1 check(s) FAILED for /fixture/bypass-pic12f675-cd4053_simple_simcal.hex' \
        > "$signature_log"
    pic12f675_classify_checker_result 1 gpsim:press-early \
        pic12f675-test-gpsim "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: incomplete PIC12F675 gpsim failure received kill credit" >&2
        exit 1
    }
    write_pic12_gpsim_fixture \
        'FAIL: PRESS1: LED (GP0) should be on mid-press (toggle-on-press), GPIO=0x0' \
        cd4053_simple > "$signature_log"
    pic12f675_classify_checker_result 1 gpsim:press-led \
        pic12f675-test-gpsim "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 gpsim press signature was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' \
        'FAIL: lock-step divergence at iter 7 (in=1): fw(ps=0 es=0 dc=8) != model(ps=1 es=1 dc=25)' \
        'PIC_TARGET_RESULT format=1 device=pic12f675 lane=lockstep variant=cd4053_simple status=fail checks=3005 failures=1' \
        > "$signature_log"
    pic12f675_classify_checker_result 1 lockstep:divergence \
        'PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 lock-step signature was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' \
        '  inject relay coils    @0x005: 0x20 -> 0x22  (fixture, from BYPASS)' \
        '    FAIL: init=0x20 requested=0x22 read=0x22 injection=1 deenergized=1 deenergize-cycles=826 partial-clear=0 spin=1 GP1=0.000V GP2=0.000V resets=1 reset-coil-ms=0.960 set-coil-ms=0.000 final-gpio=0x20 clean=1' \
        'PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=fail checks=43 failures=1' \
        > "$signature_log"
    pic12f675_classify_checker_result 1 resync:minimum-pulse \
        'PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 relay-minimum signature was not classified as killed" >&2
        exit 1
    }
    # A recovery pulse that still clears the 4 ms floor must NOT satisfy this
    # signature: the regex is what separates "too short to resynchronize" from
    # any other fault-lane failure.
    printf '%s\n' \
        '  inject relay coils    @0x005: 0x20 -> 0x22  (fixture, from BYPASS)' \
        '    FAIL: init=0x20 requested=0x22 read=0x22 injection=1 deenergized=1 deenergize-cycles=826 partial-clear=0 spin=1 GP1=0.000V GP2=0.000V resets=1 reset-coil-ms=11.312 set-coil-ms=0.000 final-gpio=0x20 clean=1' \
        'PIC_TARGET_RESULT format=1 device=pic12f675 lane=fault variant=tq2_l2_5v_relay status=fail checks=43 failures=1' \
        > "$signature_log"
    pic12f675_classify_checker_result 1 resync:minimum-pulse \
        'PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: an above-minimum recovery pulse satisfied the relay-minimum signature" >&2
        exit 1
    }
    printf '%s\n' \
        'SOAK FAIL [0.0001 h]: unexpected WDT reset (cumulative: 1)' \
        'SOAK_RESULT format=1 status=fail combination=mutation-wdt duration_ms=2500 liveness_interval_ms=1000 checks=1 failures=1 watchdog_failures=1 liveness_failures=0' \
        > "$signature_log"
    pic12f675_classify_checker_result 1 soak:wdt-reset \
        'PIC12F675_SOAK_VARIANT=cd4053_simple PIC12F675_SOAK_DURATION_MS=2500 PIC12F675_SOAK_LIVENESS_INTERVAL_MS=1000 PIC12F675_SOAK_COMBINATION_NAME=mutation-wdt pic12f675-test-soak' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = killed ] || {
        echo "ERROR: PIC12F675 soak signature was not classified as killed" >&2
        exit 1
    }
    printf '%s\n' 'FAIL: variant cd4053_simple did not compile for PIC12F675' \
        > "$signature_log"
    pic12f675_classify_checker_result 2 fault:ADCON0.ADON \
        'PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = compile-error ] || {
        echo "ERROR: PIC12F675 compile failure was not classified as an error" >&2
        exit 1
    }
    : > "$signature_log"
    pic12f675_classify_checker_result 124 fault:ADCON0.ADON \
        'PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = infrastructure-error ] || {
        echo "ERROR: PIC12F675 timeout was not classified as infrastructure" >&2
        exit 1
    }
    pic12f675_classify_checker_result 0 fault:ADCON0.ADON \
        'PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: PIC12F675 zero exit without a completion record was accepted" >&2
        exit 1
    }
    printf '%s\n' \
        '=== PIC12F675 target fault/lock-step/I-O PASS (variant cd4053_simple): PIC12F675_MATRIX_SHA256 format=2 fixture ===' \
        > "$signature_log"
    pic12f675_classify_checker_result 0 fault:ADCON0.ADON \
        'PIC12F675_TARGET_VARIANT=cd4053_simple pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = survived ] || {
        echo "ERROR: PIC12F675 complete zero-exit checker was not classified as survived" >&2
        exit 1
    }
    pic12f675_classify_checker_result 0 fault:ADCON0.ADON \
        'PIC12F675_TARGET_VARIANT=tq2_l2_5v_relay pic12f675-test-target' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: PIC12F675 target completion accepted the wrong variant" >&2
        exit 1
    }
    write_pic12_gpsim_fixture > "$signature_log"
    pic12f675_classify_checker_result 0 gpsim:press-led \
        pic12f675-test-gpsim "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = survived ] || {
        echo "ERROR: PIC12F675 complete gpsim checker was not classified as survived" >&2
        exit 1
    }
    printf '%s\n' \
        'SOAK_RESULT format=1 status=pass combination=mutation-wdt duration_ms=2500 liveness_interval_ms=1000 checks=2 failures=0 watchdog_failures=0 liveness_failures=0' \
        > "$signature_log"
    pic12f675_classify_checker_result 0 soak:wdt-reset \
        'PIC12F675_SOAK_VARIANT=cd4053_simple PIC12F675_SOAK_DURATION_MS=2500 PIC12F675_SOAK_LIVENESS_INTERVAL_MS=1000 PIC12F675_SOAK_COMBINATION_NAME=mutation-wdt pic12f675-test-soak' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = survived ] || {
        echo "ERROR: PIC12F675 complete soak checker was not classified as survived" >&2
        exit 1
    }
    pic12f675_classify_checker_result 0 soak:wdt-reset \
        'PIC12F675_SOAK_VARIANT=cd4053_simple PIC12F675_SOAK_DURATION_MS=2000 PIC12F675_SOAK_LIVENESS_INTERVAL_MS=1000 PIC12F675_SOAK_COMBINATION_NAME=mutation-wdt pic12f675-test-soak' \
        "$signature_log"
    [ "$PIC12F675_CHECKER_OUTCOME" = checker-error ] || {
        echo "ERROR: PIC12F675 soak completion accepted the wrong duration" >&2
        exit 1
    }
    for policy in PIC PIC,ATtiny202 1; do
        mutation_partial_result_is_allowed "$MUTATION_EXPECTED_PIC12F675" 0 \
            "$policy" 0 || {
            echo "ERROR: policy $policy rejected a tools-absent PIC lane" >&2
            exit 1
        }
    done
    for policy in ATtiny202 PIC,ATtiny202 1; do
        mutation_partial_result_is_allowed 0 "$MUTATION_EXPECTED_XT" \
            "$policy" 0 || {
            echo "ERROR: policy $policy rejected a tools-absent ATtiny202 lane" >&2
            exit 1
        }
    done
    for policy in 0 ATtiny202; do
        if mutation_partial_result_is_allowed "$MUTATION_EXPECTED_PIC12F675" 0 \
                "$policy" 0; then
            echo "ERROR: policy $policy accepted an unauthorized PIC skip" >&2
            exit 1
        fi
    done
    for policy in 0 PIC; do
        if mutation_partial_result_is_allowed 0 "$MUTATION_EXPECTED_XT" \
                "$policy" 0; then
            echo "ERROR: policy $policy accepted an unauthorized ATtiny202 skip" >&2
            exit 1
        fi
    done
    for policy in 0 1 PIC ATtiny202 PIC,ATtiny202; do
        if mutation_partial_result_is_allowed 1 0 "$policy" 1; then
            echo "ERROR: policy $policy accepted a failed baseline" >&2
            exit 1
        fi
    done
    xt_policy_dfp="$RESULT_DIR/xt-policy-dfp"
    xt_policy_venv="$RESULT_DIR/xt-policy-venv"
    xt_policy_bin="$RESULT_DIR/xt-policy-bin"
    mkdir -p "$xt_policy_dfp/gcc/dev/$XT_MCU/device-specs" \
        "$xt_policy_dfp/gcc/dev/$XT_MCU/avrxmega3/short-calls" \
        "$xt_policy_dfp/include/avr" "$xt_policy_venv/bin" "$xt_policy_bin"
    : > "$xt_policy_dfp/gcc/dev/$XT_MCU/device-specs/specs-$XT_MCU"
    : > "$xt_policy_dfp/gcc/dev/$XT_MCU/avrxmega3/short-calls/crt$XT_MCU.o"
    : > "$xt_policy_dfp/gcc/dev/$XT_MCU/avrxmega3/short-calls/lib$XT_MCU.a"
    : > "$xt_policy_dfp/include/avr/iotn202.h"
    for tool in python avr-objdump avr-nm; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$xt_policy_bin/$tool"
        chmod 750 "$xt_policy_bin/$tool"
    done
    cp "$xt_policy_bin/python" "$xt_policy_venv/bin/python"
    XT_MUTATION_OBJDUMP="$xt_policy_bin/avr-objdump" \
        XT_MUTATION_NM="$xt_policy_bin/avr-nm" \
        mutation_attiny202_tools_are_available "$xt_policy_dfp" "$xt_policy_venv" \
        || { echo "ERROR: complete ATtiny202 policy fixture was rejected" >&2; exit 1; }
    if STRICT_TOOLS=1 XT_MUTATION_OBJDUMP="$RESULT_DIR/missing-objdump" \
            XT_MUTATION_NM="$xt_policy_bin/avr-nm" \
            mutation_attiny202_tools_are_available "$xt_policy_dfp" \
                "$xt_policy_venv"; then
        echo "ERROR: absent ATtiny202 binutils was accepted under strict mode" >&2
        exit 1
    fi
    saved_pic12_cc=$PIC12F675_MUTATION_CC
    saved_pic12_dfp=$PIC12F675_MUTATION_DFP
    saved_pic12_python=$PIC12F675_MUTATION_PYTHON
    saved_mutation_make=$MUTATION_MAKE
    saved_mutation_timeout=$MUTATION_TIMEOUT_S
    PIC12F675_MUTATION_CC="$RESULT_DIR/missing-xc8"
    PIC12F675_MUTATION_DFP="$RESULT_DIR/missing-dfp"
    PIC12F675_MUTATION_PYTHON="$RESULT_DIR/missing-python"
    PIC12F675_OK=1; PIC12F675_WHY=fixture; MUT_BASELINE_FAILED=0
    probe_pic12f675_baseline "$RESULT_DIR" >"$RESULT_DIR/pic12-absent.log" 2>&1
    pic12_probe_rc=$?
    if [ "$pic12_probe_rc" -eq 0 ] || [ "$PIC12F675_OK" -ne 0 ] \
            || [ "$PIC12F675_WHY" != 'tools absent' ] \
            || [ "$MUT_BASELINE_FAILED" -ne 0 ]; then
        echo "ERROR: PIC12F675 absent-tool probe unexpectedly enabled its lane" >&2
        exit 1
    fi
    fake_pic12_tools="$RESULT_DIR/pic12-baseline-tools"
    fake_pic12_dfp="$RESULT_DIR/pic12-baseline-dfp"
    fake_pic12_make="$RESULT_DIR/pic12-baseline-make"
    fake_pic12_root="$RESULT_DIR/pic12-baseline-root"
    mkdir -p "$fake_pic12_tools" "$fake_pic12_dfp/pic/include/proc" \
        "$fake_pic12_root"
    : > "$fake_pic12_dfp/pic/include/proc/pic12f675.h"
    cat > "$fake_pic12_tools/tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$fake_pic12_make" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_PIC12_BASELINE_MODE:?}" in
    fail) exit 42 ;;
    timeout) sleep 30 ;;
    incomplete) exit 0 ;;
    *) exit 96 ;;
esac
EOF
    chmod 750 "$fake_pic12_tools/tool" "$fake_pic12_make"
    PIC12F675_MUTATION_CC="$fake_pic12_tools/tool"
    PIC12F675_MUTATION_DFP="$fake_pic12_dfp"
    PIC12F675_MUTATION_PYTHON="$fake_pic12_tools/tool"
    MUTATION_MAKE="$fake_pic12_make"
    for pic12_fixture in fail timeout incomplete; do
        MUT_BASELINE_FAILED=0; PIC12F675_OK=1; PIC12F675_WHY=fixture
        if [ "$pic12_fixture" = timeout ]; then MUTATION_TIMEOUT_S=0.1; else MUTATION_TIMEOUT_S=1; fi
        export FAKE_PIC12_BASELINE_MODE=$pic12_fixture
        probe_pic12f675_baseline "$fake_pic12_root" \
            >"$RESULT_DIR/pic12-$pic12_fixture.log" 2>&1
        pic12_probe_rc=$?
        case "$pic12_fixture" in
            fail) expected_pic12_reason='pic12f675-simcal baseline FAILED' ;;
            timeout) expected_pic12_reason='pic12f675-simcal baseline TIMEOUT' ;;
            incomplete) expected_pic12_reason='pic12f675-simcal baseline INCOMPLETE' ;;
        esac
        if [ "$pic12_probe_rc" -eq 0 ] || [ "$PIC12F675_OK" -ne 0 ] \
                || [ "$PIC12F675_WHY" != "$expected_pic12_reason" ] \
                || [ "$MUT_BASELINE_FAILED" -ne 1 ]; then
            echo "ERROR: PIC12F675 $pic12_fixture baseline classification failed" >&2
            exit 1
        fi
    done
    [ -f "$fake_pic12_root/.mutation-pic12f675-simcal-baseline.log" ] \
        && [ ! -e "$RESULT_DIR/.mutation-pic12f675-simcal-baseline.log" ] || {
        echo "ERROR: PIC12F675 baseline log escaped its disposable sandbox" >&2
        exit 1
    }
    unset FAKE_PIC12_BASELINE_MODE
    PIC12F675_MUTATION_CC=$saved_pic12_cc
    PIC12F675_MUTATION_DFP=$saved_pic12_dfp
    PIC12F675_MUTATION_PYTHON=$saved_pic12_python
    MUTATION_MAKE=$saved_mutation_make
    MUTATION_TIMEOUT_S=$saved_mutation_timeout
    pic12_source_fixture="$RESULT_DIR/pic12-source-mutations"
    mkdir "$pic12_source_fixture"
    pic12_mutation_index=0
    for entry in "${PIC12F675_MUTATIONS[@]}"; do
        pic12_mutation_index=$((pic12_mutation_index + 1))
        mutation_parse_record "PIC12F675 source selftest" 5 "$entry" || exit 1
        file=${MUTATION_RECORD_FIELDS[0]}
        sed_expr=${MUTATION_RECORD_FIELDS[1]}
        signature=${MUTATION_RECORD_FIELDS[3]}
        case "$signature" in
            fault:*|gpsim:press-led|gpsim:press-early|lockstep:divergence|\
            resync:minimum-pulse|soak:wdt-reset|resync:coil|resync:physical-coil) ;;
            *) echo "ERROR: PIC12F675 mutation has an unknown signature: $signature" >&2
               exit 1 ;;
        esac
        mutation_fixture="$pic12_source_fixture/$pic12_mutation_index.c"
        cp "$PROJ_DIR/$file" "$mutation_fixture" || exit 1
        sed -i "$sed_expr" "$mutation_fixture" || {
            echo "ERROR: PIC12F675 self-test could not apply mutation $pic12_mutation_index" >&2
            exit 1
        }
        if cmp -s "$mutation_fixture" "$PROJ_DIR/$file"; then
            echo "ERROR: PIC12F675 mutation $pic12_mutation_index did not change $file" >&2
            exit 1
        fi
    done
    [ "$pic12_mutation_index" -eq "$MUTATION_EXPECTED_PIC12F675" ] || {
        echo "ERROR: PIC12F675 source mutation self-test count drifted" >&2
        exit 1
    }
    if mutation_parse_record selftest 4 $'a\tb\t\td' >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted an empty record field" >&2; exit 1
    fi
    if mutation_parse_record selftest 4 $'a\tb\tc\td\nextra' >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted a newline in a record" >&2; exit 1
    fi
    if mutation_parse_record selftest 4 $'a\tb\tc\td\x1fextra' >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted its packed-record delimiter" >&2; exit 1
    fi
    split_mutation_make_command selftest 'test-model-check' || exit 1
    [ "${MUTATION_MAKE_ARGS[*]}" = 'test-model-check' ] || {
        echo "ERROR: mutation accounting split a plain Make target incorrectly" >&2; exit 1
    }
    split_mutation_make_command selftest \
        'PIC10F320_VARIANT=cd4053_simple pic10f320-test-actuation' || exit 1
    [ "${MUTATION_MAKE_ARGS[0]}" = 'PIC10F320_VARIANT=cd4053_simple' ] \
        && [ "${MUTATION_MAKE_ARGS[1]}" = 'pic10f320-test-actuation' ] || {
        echo "ERROR: mutation accounting split an assignment target incorrectly" >&2; exit 1
    }
    fake_make="$RESULT_DIR/fake-make"
    make_log="$RESULT_DIR/fake-make.log"
    cat > "$fake_make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${MUTATION_MAKE_LOG:?}"
[ -z "${MUTATION_NM_LOG:-}" ] || printf '%s\n' "${AVR_NM-}" > "$MUTATION_NM_LOG"
EOF
    chmod 750 "$fake_make"
    real_mutation_make=$MUTATION_MAKE
    MUTATION_MAKE=$fake_make MUTATION_MAKE_LOG=$make_log \
        run_mutation_make_command /fixture \
            'PIC10F320_VARIANT=cd4053_simple pic10f320-test-actuation' \
            GPSIM=fake || exit 1
    MUTATION_MAKE=$real_mutation_make
    mapfile -t make_argv < "$make_log"
    expected_make_argv=(-C /fixture GPSIM=fake \
        PIC10F320_VARIANT=cd4053_simple pic10f320-test-actuation)
    [ "${make_argv[*]}" = "${expected_make_argv[*]}" ] || {
        echo "ERROR: mutation Make runner forwarded incorrect argv" >&2; exit 1
    }
    nm_log="$RESULT_DIR/fake-make-nm.log"
    MUTATION_MAKE=$fake_make MUTATION_MAKE_LOG=$make_log \
        MUTATION_NM_LOG=$nm_log run_mutation_make_command /fixture \
            attiny202-delay-oracle || exit 1
    [ "$(<"$nm_log")" = "$XT_MUTATION_NM" ] \
        && ! grep -q '^AVR_NM=' "$make_log" || {
        echo "ERROR: selected AVR_NM did not cross the sandbox as environment only" >&2
        exit 1
    }
    relative_nm=$(mutation_command_for_sandbox test/run_mutation_tests.sh)
    [ "$relative_nm" = "$PROJ_DIR/test/run_mutation_tests.sh" ] || {
        echo "ERROR: relative mutation tool path was not anchored to the repository" >&2
        exit 1
    }

    fake_pic_make="$RESULT_DIR/fake-pic-baseline-make"
    fake_gpsim="$RESULT_DIR/fake-gpsim"
    fake_pic_dfp="$RESULT_DIR/fake-pic-dfp"
    stale_hex_root="$RESULT_DIR/pic-baseline"
    gpsim_log="$RESULT_DIR/fake-gpsim.log"
    pic_probe_log="$RESULT_DIR/pic-baseline.log"

    # An authorized PIC omission remains tools-absent under inherited strict
    # mode: the probe must stop before Make turns the missing compiler into a
    # failed baseline.
    strict_absent_log="$RESULT_DIR/pic-strict-absent.log"
    rm -rf "$stale_hex_root"
    mkdir -p "$stale_hex_root"
    PIC_GPSIM_OK=1
    PIC_GPSIM_WHY="fixture"
    MUT_BASELINE_FAILED=0
    pic_probe_rc=0
    STRICT_TOOLS=1 MUTATION_MAKE="$fake_pic_make" \
        PIC12F675_MUTATION_CC="$RESULT_DIR/missing-xc8" \
        probe_pic10f322_gpsim_baseline "$stale_hex_root" \
            >"$strict_absent_log" 2>&1 || pic_probe_rc=$?
    [ "$pic_probe_rc" -ne 0 ] && [ "$PIC_GPSIM_OK" -eq 0 ] \
        && [ "$PIC_GPSIM_WHY" = "tools absent" ] \
        && [ "$MUT_BASELINE_FAILED" -eq 0 ] \
        && [ ! -e "$stale_hex_root/$PIC10F322_MUTATION_HEX" ] \
        && grep -Fq 'XC8/DFP absent' "$strict_absent_log" || {
        echo "ERROR: strict authorized PIC omission became a baseline failure" >&2
        exit 1
    }

    # A failed baseline build must dominate a stale, apparently usable HEX. Use
    # an ordinary nonzero status (which is a legitimate kill for a mutant) to
    # prove it is treated as baseline infrastructure here, before dispatch.
    cat > "$fake_pic_make" <<'EOF'
#!/usr/bin/env bash
root=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -C ]; then root=$2; shift 2; else shift; fi
done
mkdir -p "$(dirname "$root/${PIC_BASELINE_STALE_HEX:?}")"
printf ':020000040000FA\n:00000001FF\n' > "$root/$PIC_BASELINE_STALE_HEX"
exit 42
EOF
    cat > "$fake_gpsim" <<'EOF'
#!/usr/bin/env bash
: > "${PIC_GPSIM_SELFTEST_LOG:?}"
cat <<'SNAPSHOTS'
===INIT_BYPASS===
porta = 0x8
lata = 0x0
===PRESS1_EARLY===
porta = 0x0
lata = 0x0
===PRESS1_LOW===
porta = 0x0
lata = 0x3
===ENGAGED===
porta = 0xb
lata = 0x3
===BYPASS_AGAIN===
porta = 0x8
lata = 0x0
SNAPSHOTS
exit 0
EOF
    mkdir -p "$fake_pic_dfp/pic/include/proc"
    : > "$fake_pic_dfp/pic/include/proc/pic10f322.h"
    chmod 750 "$fake_pic_make" "$fake_gpsim"
    rm -rf "$stale_hex_root"
    mkdir -p "$stale_hex_root"
    PIC_GPSIM_OK=1
    PIC_GPSIM_WHY="tools absent"
    MUT_BASELINE_FAILED=0
    pic_probe_rc=0
    MUTATION_MAKE="$fake_pic_make" \
        PIC_BASELINE_STALE_HEX="$PIC10F322_MUTATION_HEX" \
        PIC12F675_MUTATION_CC="$fake_gpsim" \
        PIC12F675_MUTATION_DFP="$fake_pic_dfp" \
        GPSIM="$fake_gpsim" PIC_GPSIM_SELFTEST_LOG="$gpsim_log" \
        probe_pic10f322_gpsim_baseline "$stale_hex_root" \
            >"$pic_probe_log" 2>&1 || pic_probe_rc=$?
    [ "$pic_probe_rc" -ne 0 ] || {
        echo "ERROR: failed PIC baseline build was accepted" >&2; exit 1
    }
    [ -f "$stale_hex_root/$PIC10F322_MUTATION_HEX" ] || {
        echo "ERROR: PIC baseline regression did not leave its stale HEX" >&2; exit 1
    }
    [ ! -e "$gpsim_log" ] || {
        echo "ERROR: failed PIC baseline build reached gpsim through a stale HEX" >&2; exit 1
    }
    [ "$PIC_GPSIM_OK" -eq 0 ] || {
        echo "ERROR: failed PIC baseline build enabled gpsim mutants" >&2; exit 1
    }
    [ "$PIC_GPSIM_WHY" = "baseline FAILED" ] || {
        echo "ERROR: failed PIC baseline build has the wrong skip reason" >&2; exit 1
    }
    [ "$MUT_BASELINE_FAILED" -eq 1 ] || {
        echo "ERROR: failed PIC baseline build did not latch infrastructure failure" >&2; exit 1
    }
    grep -Fq 'baseline build FAILED (status 42)' "$pic_probe_log" \
        && ! grep -Eq 'ENABLED|killed' "$pic_probe_log" || {
        echo "ERROR: failed PIC baseline build was not reported fail-closed" >&2; exit 1
    }
    unpack_mutation_job_spec \
        "fixture$US""picgpsim$US$US""src/file.c$US""s@a@b@$US""description" \
        || exit 1
    [ "$kind" = picgpsim ] && [ -z "$arg" ] && [ "$file" = src/file.c ] || {
        echo "ERROR: mutation accounting unpacked a valid job incorrectly" >&2; exit 1
    }
    if unpack_mutation_job_spec \
            "fixture$US""picgpsim$US$US""src/file.c$US""sed$US""desc$US""extra" \
            >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted an overlong packed job" >&2; exit 1
    fi
    # Every dispatchable kind must round-trip. `avrxt` is here because it was
    # added by one branch while this validator was added by another: the kinds
    # the pool can emit and the kinds it will accept are two lists that must be
    # kept in step, and nothing else in the suite compares them.
    unpack_mutation_job_spec \
        "fixture$US""avrxt$US""XT_SIM_VARIANT=cd4053_simple attiny202-sim$US""src/f.c$US""s@a@b@$US""d" \
        || exit 1
    [ "$kind" = avrxt ] && [ "$arg" = 'XT_SIM_VARIANT=cd4053_simple attiny202-sim' ] || {
        echo "ERROR: mutation accounting unpacked an ATtiny202 job incorrectly" >&2; exit 1
    }
    if unpack_mutation_job_spec \
            "fixture$US""notakind$US""t$US""src/f.c$US""s@a@b@$US""d" >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted an unknown job kind" >&2; exit 1
    fi
    publish_mutation_result "$RESULT_DIR/selftest-valid" killed \
        '[selftest-valid] killed   (fixture): valid result' || exit 1
    mutation_read_status selftest-valid "$RESULT_DIR/selftest-valid.status" || exit 1
    mutation_validate_output selftest-valid "$RESULT_DIR/selftest-valid.out" \
        "$MUTATION_STATUS" || exit 1
    printf 'killed\ntrailing\n' > "$RESULT_DIR/selftest.status"
    if mutation_read_status selftest "$RESULT_DIR/selftest.status" >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted trailing status data" >&2; exit 1
    fi
    printf 'killed' > "$RESULT_DIR/selftest-no-newline.status"
    if mutation_read_status selftest-no-newline \
            "$RESULT_DIR/selftest-no-newline.status" >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted an unterminated status" >&2; exit 1
    fi
    echo "mutation sandbox/accounting validation: 133 checks, 0 failures"
    exit 0
fi

# Sanity: the unmutated tree must PASS every target we rely on, otherwise a
# "killed" result is meaningless (it would just mean the baseline is broken).
# Baseline-check EVERY distinct kill target the MUTATIONS list uses -- not just
# test-sim-attiny13a -- so a mutant killed by e.g. test-model-check can never be a false
# kill against a baseline that was never verified. (The PIC-shell mutants have
# their own baseline probe below, since their tools may be absent.)
echo "=== mutation testing: baseline sanity check ==="
if ! BASE_DIR="$(mktemp -d "$RESULT_DIR/baseline.XXXXXX")"; then
    echo "ERROR: could not create mutation baseline sandbox" >&2
    exit 2
fi
if ! copy_tree "$BASE_DIR"; then
    echo "ERROR: could not populate mutation baseline sandbox" >&2
    rm -rf "$BASE_DIR"
    exit 2
fi
if ! validate_pic10f320_sandbox "$BASE_DIR"; then
    rm -rf "$BASE_DIR"
    exit 2
fi
for t in "${HOST_BASE_TARGETS[@]}"; do
    if run_mutation_make_command "$BASE_DIR" "$t" >/dev/null 2>&1; then
        echo "baseline $t: PASS"
    else
        echo "ERROR: baseline $t FAILS on unmutated tree; aborting." >&2
        rm -rf "$BASE_DIR"
        exit 2
    fi
done
rm -rf "$BASE_DIR"
echo

# Collect the core/AVR mutants (always run). Dispatch happens once, after the PIC
# probe below has decided which PIC subsets are eligible.
core_cat="${#MUTATIONS[@]} core/AVR mutants"
for entry in "${MUTATIONS[@]}"; do
    mutation_parse_record "core/AVR collection" 4 "$entry" || exit 2
    file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
    target=${MUTATION_RECORD_FIELDS[2]}; desc=${MUTATION_RECORD_FIELDS[3]}
    case "$target" in
        host:*'|'*) job_specs+=("$core_cat$US""pic12f675$US$target$US$file$US$sed_expr$US$desc") ;;
        *) job_specs+=("$core_cat$US""make$US$target$US$file$US$sed_expr$US$desc") ;;
    esac
done

# PIC10F320 host-lane mutants: only a C compiler is required, so these ride with
# the core batch and are never skipped.
p320_host_cat="${#PIC10F320_HOST_MUTATIONS[@]} PIC10F320 host mutants (equiv/actuation/fault)"
for entry in "${PIC10F320_HOST_MUTATIONS[@]}"; do
    mutation_parse_record "PIC10F320 host collection" 4 "$entry" || exit 2
    file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
    target=${MUTATION_RECORD_FIELDS[2]}; desc=${MUTATION_RECORD_FIELDS[3]}
    job_specs+=("$p320_host_cat$US""make$US$target$US$file$US$sed_expr$US$desc")
done

# --- PIC toolchain probe ------------------------------------------------------
# Enable the PIC-shell mutants only when the PIC tools are present AND the
# UNMUTATED tree genuinely PASSES (a clean skip is NOT a pass). pic10f322-test-gpsim /
# pic10f322-test-soak both exit 0 when their tools are absent, so without this gate an
# unguarded PIC mutant would be a false "survivor" on any box lacking XC8/gpsim.
PIC_GPSIM_OK=0
PIC_SOAK_OK=0
PIC_TARGET_OK=0
# Why a lane ended up disabled, carried to the summary. "tools absent" and
# "baseline FAILED" demand opposite responses from the reader -- install
# something, versus go debug something -- and the summary used to assert the
# former unconditionally, which is how a complete toolchain got blamed for a
# sandbox bug. MUT_BASELINE_FAILED latches if ANY lane failed for the second
# reason, so the closing advice can stop recommending a package install.
PIC_GPSIM_WHY="tools absent"
PIC_SOAK_WHY="tools absent"
PIC_TARGET_WHY="tools absent"
PIC10F320_TOOL_WHY="tools absent"
MUT_BASELINE_FAILED=0
echo
echo "=== PIC toolchain probe (gates the PIC-shell mutants) ==="
if ! PIC_BASE="$(mktemp -d "$RESULT_DIR/pic-baseline.XXXXXX")"; then
    echo "ERROR: could not create PIC mutation probe sandbox" >&2
    exit 2
fi
if ! copy_tree "$PIC_BASE"; then
    echo "ERROR: could not populate PIC mutation probe sandbox" >&2
    rm -rf "$PIC_BASE"
    exit 2
fi
# The baseline probes are bounded for the same reason the mutants are: they run
# the same soak and the same simulator, and a hang here stalls the run before a
# single mutant is dispatched. A probe that times out reports as "baseline
# FAILED", which skips its lane and sets MUT_BASELINE_FAILED -- so it still fails
# closed under MUTATION_ALLOW_SKIP=0 rather than quietly shrinking the run.
if probe_pic10f322_gpsim_baseline "$PIC_BASE"; then
    if command -v "$PIC_SOAK_CXX" >/dev/null 2>&1 \
       && [ -f "$PIC_SOAK_GPSIM_INC/sim_context.h" ] \
       && pkg-config --exists glib-2.0 2>/dev/null; then
        if mutation_bounded "$MUTATION_MAKE" -C "$PIC_BASE" pic10f322-test-soak \
                PIC10F322_SOAK_DURATION_MS="$PIC_SOAK_MUT_MS" \
                PIC10F322_SOAK_LIVENESS_INTERVAL_MS="$PIC_SOAK_MUT_LIVENESS_MS" \
                PIC10F322_SOAK_VARIANT=cd4053_simple >/dev/null 2>&1; then
            PIC_SOAK_OK=1
            echo "gpsim-dev + glib + $PIC_SOAK_CXX present, soak baseline PASS -> WDT mutant ENABLED"
        else
            PIC_SOAK_WHY="baseline FAILED"
            MUT_BASELINE_FAILED=1
            echo "soak baseline did not pass cleanly -> WDT (soak) mutant SKIPPED"
        fi
        if mutation_bounded "$MUTATION_MAKE" -C "$PIC_BASE" pic10f322-test-target-variants >/dev/null 2>&1; then
            PIC_TARGET_OK=1
            echo "target aggregate baseline PASS -> PIC target mutants ENABLED"
        else
            PIC_TARGET_WHY="baseline FAILED"
            MUT_BASELINE_FAILED=1
            echo "target aggregate baseline did not pass cleanly -> PIC target mutants SKIPPED"
        fi
    else
        echo "gpsim-dev/glib/$PIC_SOAK_CXX absent -> WDT (soak) mutant SKIPPED"
    fi
fi
rm -rf "$PIC_BASE"

# --- PIC10F320 toolchain probe -----------------------------------------------
# Same discipline as the PIC10F322 probe above: the tool-dependent PIC10F320
# mutants are enabled only when the tools exist AND every DISTINCT kill command
# passes on the unmutated sandbox. Testing only pic10f320-test-target-variants does
# not baseline pic10f320-test-gpsim or pic10f320-test-soak; worse, a missing wrapper in
# either mutant sandbox then produces a nonzero status that is falsely scored as
# a kill. pic10f320-test-{gpsim,target,soak} can all skip with status 0, so the outer
# tool checks and exact per-command baselines are both required.
PIC10F320_TOOL_OK=0
echo
echo "=== PIC10F320 toolchain probe (gates its tool-dependent mutants) ==="
if ! P320_BASE="$(mktemp -d "$RESULT_DIR/pic320-baseline.XXXXXX")"; then
    echo "ERROR: could not create PIC10F320 mutation probe sandbox" >&2
    exit 2
fi
if ! copy_tree "$P320_BASE"; then
    echo "ERROR: could not populate PIC10F320 mutation probe sandbox" >&2
    rm -rf "$P320_BASE"
    exit 2
fi
if ! validate_pic10f320_sandbox "$P320_BASE"; then
    rm -rf "$P320_BASE"
    exit 2
fi
echo "PIC10F320 mutation sandbox helpers: PASS"

if ! mutation_command_is_available "$PIC10F320_MUTATION_CC" \
        || [ ! -f "$PIC10F320_MUTATION_DFP/pic/include/proc/pic10f320.h" ] \
        || ! mutation_command_is_available "$GPSIM" \
        || ! mutation_command_is_available "$PIC10F320_SOAK_CXX" \
        || ! mutation_command_is_available pkg-config \
        || [ ! -f "$PIC10F320_SOAK_GPSIM_INC/sim_context.h" ] \
        || ! pkg-config --exists glib-2.0 2>/dev/null; then
    echo "XC8/gpsim/libgpsim absent -> PIC10F320 tool mutants SKIPPED"
elif ! mutation_bounded "$MUTATION_MAKE" -C "$P320_BASE" \
        pic10f320-variants >/dev/null 2>&1; then
    PIC10F320_TOOL_WHY="baseline FAILED"
    MUT_BASELINE_FAILED=1
    echo "PIC10F320 baseline build failed -> its tool mutants SKIPPED"
else
    P320_BASELINES_OK=1
    for target in "${PIC10F320_BASE_TARGETS[@]}"; do
        # Intentional word splitting: each field contains optional VAR=value
        # assignments followed by one Make target, validated and tokenized by
        # the same helper used for mutant execution.
        if run_mutation_make_command "$P320_BASE" "$target" \
                "GPSIM=$GPSIM" >/dev/null 2>&1; then
            echo "baseline $target: PASS"
        else
            echo "baseline $target: FAIL"
            P320_BASELINES_OK=0
        fi
    done
    if [ "$P320_BASELINES_OK" -eq 1 ]; then
        PIC10F320_TOOL_OK=1
        echo "XC8 + gpsim + libgpsim present, all baselines PASS -> PIC10F320 tool mutants ENABLED"
    else
        PIC10F320_TOOL_WHY="baseline FAILED"
        MUT_BASELINE_FAILED=1
        echo "a PIC10F320 kill-target baseline failed -> its tool mutants SKIPPED"
    fi
fi
rm -rf "$P320_BASE"

# --- PIC12F675 toolchain probe ------------------------------------------------
# Same discipline as both probes above, with one part-specific addition: the
# sandbox check runs FIRST, because this part's lanes all consume a DERIVED
# image and a sandbox that cannot derive one skips every lane with status 0.
# Every distinct kill command is baselined on the unmutated tree, again derived
# from the table itself rather than written out here -- a mutant whose kill
# command was never baselined is a mutant whose nonzero status could mean
# "sandbox broken" rather than "fault detected".
#
# Tool absence is the ONLY skippable outcome. A producer or kill-target baseline
# that times out, fails, or returns zero without its completion record latches
# MUT_BASELINE_FAILED and makes the final run fail even in explicit partial mode.
# This distinction matters most for pic12f675-simcal: the old compound `if`
# called every nonzero producer result "tools absent" and hid a broken unmutated
# baseline whenever MUTATION_ALLOW_SKIP=1.
PIC12F675_OK=0
PIC12F675_WHY="tools absent"
echo
echo "=== PIC12F675 toolchain probe (gates its mutants) ==="
if ! P675_BASE="$(mktemp -d "$RESULT_DIR/pic675-baseline.XXXXXX")"; then
    echo "ERROR: could not create PIC12F675 mutation probe sandbox" >&2
    exit 2
fi
if ! copy_tree "$P675_BASE"; then
    echo "ERROR: could not populate PIC12F675 mutation probe sandbox" >&2
    rm -rf "$P675_BASE"
    exit 2
fi
if ! validate_pic12f675_sandbox "$P675_BASE"; then
    rm -rf "$P675_BASE"
    exit 2
fi
echo "PIC12F675 mutation sandbox helpers: PASS"

probe_pic12f675_baseline "$P675_BASE" || true
rm -rf "$P675_BASE"

# --- AVR-XT toolchain probe ---------------------------------------------------
# Same discipline as both PIC probes: enable the ATtiny202 mutants only when the
# ATtiny_DFP and the patched yasimavr venv both resolve AND every DISTINCT kill
# command passes on the unmutated sandbox. Every attiny202-* target exits 0 on a
# missing input, so the outer tool checks and the per-command baselines are both
# required -- either alone leaves a way for the whole lane to read as survivors
# on a host that simply lacks the tools.
XT_OK=0
XT_WHY="tools absent"
echo
echo "=== AVR-XT toolchain probe (gates the ATtiny202 mutants) ==="
if ! XT_BASE="$(mktemp -d "$RESULT_DIR/xt-baseline.XXXXXX")"; then
    echo "ERROR: could not create AVR-XT baseline sandbox" >&2
    exit 2
fi
copy_tree "$XT_BASE"
if ! validate_avr_xt_sandbox "$XT_BASE"; then
    rm -rf "$XT_BASE"
    exit 2
fi
echo "AVR-XT mutation sandbox files: PASS"

if mutation_attiny202_tools_are_available "$xt_dfp_abs" \
        "$xt_yasimavr_venv_abs"; then
    XT_BASELINES_OK=1
    while IFS= read -r target; do
        # Intentional word splitting: each field is optional VAR=value
        # assignments followed by one Make target, never shell metacharacters.
        if mutation_bounded "$MUTATION_MAKE" -C "$XT_BASE" $target \
                XT_DFP="$xt_dfp_abs" \
                YASIMAVR_VENV="$xt_yasimavr_venv_abs" \
                OBJDUMP="$XT_MUTATION_OBJDUMP" >/dev/null 2>&1; then
            echo "baseline $target: PASS"
        else
            echo "baseline $target: FAIL"
            XT_BASELINES_OK=0
        fi
    done < <(printf '%s\n' "${XT_MUTATIONS[@]}" | cut -f3 | sort -u)
    if [ "$XT_BASELINES_OK" -eq 1 ]; then
        XT_OK=1
        echo "ATtiny_DFP + patched yasimavr present, all baselines PASS -> ATtiny202 mutants ENABLED"
    else
        XT_WHY="baseline FAILED"
        MUT_BASELINE_FAILED=1
        echo "an ATtiny202 kill-target baseline failed -> its mutants SKIPPED"
    fi
else
    echo "ATtiny_DFP, patched yasimavr, and/or binutils-avr absent -> ATtiny202 mutants SKIPPED"
fi
rm -rf "$XT_BASE"

# Collect the enabled PIC subsets onto the same work list.
if [ "$PIC10F320_TOOL_OK" -eq 1 ]; then
    p320_tool_cat="${#PIC10F320_TOOL_MUTATIONS[@]} PIC10F320 target mutants (gpsim/libgpsim/soak)"
    for entry in "${PIC10F320_TOOL_MUTATIONS[@]}"; do
        mutation_parse_record "PIC10F320 tool collection" 4 "$entry" || exit 2
        file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
        target=${MUTATION_RECORD_FIELDS[2]}; desc=${MUTATION_RECORD_FIELDS[3]}
        job_specs+=("$p320_tool_cat$US""make$US$target$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$PIC_GPSIM_OK" -eq 1 ]; then
    gpsim_cat="${#PIC_GPSIM_MUTATIONS[@]} PIC-shell mutants (gpsim register-level)"
    for entry in "${PIC_GPSIM_MUTATIONS[@]}"; do
        mutation_parse_record "PIC gpsim collection" 3 "$entry" || exit 2
        file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
        desc=${MUTATION_RECORD_FIELDS[2]}
        job_specs+=("$gpsim_cat$US""picgpsim$US$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$PIC_SOAK_OK" -eq 1 ]; then
    soak_cat="${#PIC_SOAK_MUTATIONS[@]} PIC-shell mutant (WDT liveness, libgpsim soak ${PIC_SOAK_MUT_MS}ms)"
    for entry in "${PIC_SOAK_MUTATIONS[@]}"; do
        mutation_parse_record "PIC soak collection" 3 "$entry" || exit 2
        file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
        desc=${MUTATION_RECORD_FIELDS[2]}
        job_specs+=("$soak_cat$US""picsoak$US$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$PIC_TARGET_OK" -eq 1 ]; then
    target_cat="${#PIC_TARGET_MUTATIONS[@]} PIC target mutants (fault + lock-step + target I/O)"
    for entry in "${PIC_TARGET_MUTATIONS[@]}"; do
        mutation_parse_record "PIC target collection" 4 "$entry" || exit 2
        file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
        variant=${MUTATION_RECORD_FIELDS[2]}; desc=${MUTATION_RECORD_FIELDS[3]}
        job_specs+=("$target_cat$US""pictarget$US$variant$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$PIC12F675_OK" -eq 1 ]; then
    p675_cat="${#PIC12F675_MUTATIONS[@]} PIC12F675 mutants (gpsim/target aggregate/soak)"
    for entry in "${PIC12F675_MUTATIONS[@]}"; do
        mutation_parse_record "PIC12F675 collection" 5 "$entry" || exit 2
        file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
        target=${MUTATION_RECORD_FIELDS[2]}; signature=${MUTATION_RECORD_FIELDS[3]}
        desc=${MUTATION_RECORD_FIELDS[4]}
        job_specs+=("$p675_cat$US""pic12f675$US$signature|$target$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$XT_OK" -eq 1 ]; then
    xt_cat="${#XT_MUTATIONS[@]} ATtiny202 shell mutants (yasimavr sim/lock-step/fault/soak + delay oracle)"
    for entry in "${XT_MUTATIONS[@]}"; do
        mutation_parse_record "ATtiny202 collection" 4 "$entry" || exit 2
        file=${MUTATION_RECORD_FIELDS[0]}; sed_expr=${MUTATION_RECORD_FIELDS[1]}
        target=${MUTATION_RECORD_FIELDS[2]}; desc=${MUTATION_RECORD_FIELDS[3]}
        job_specs+=("$xt_cat$US""avrxt$US$target$US$file$US$sed_expr$US$desc")
    done
fi

# --- dispatch every collected mutant through the bounded-parallel pool ---------
# Each mutant gets a stable 1-based index (its position in job_specs) so its
# result files and the ordered replay below line up regardless of finish order.
echo
echo "=== running ${#job_specs[@]} mutants across up to $MUTATION_JOBS parallel job(s) ==="
job_cat=("")   # 1-based; index 0 unused
idx=0
for spec in "${job_specs[@]}"; do
    idx=$((idx + 1))
    unpack_mutation_job_spec "$spec" || exit 2
    job_cat[idx]="$category"
    dispatch "$idx" "$kind" "$arg" "$file" "$sed_expr" "$desc"
done
drain_workers

# --- tally + ordered replay ---------------------------------------------------
# Read the per-mutant result files in index order so the log and the survivor
# list are deterministic no matter how the pool interleaved the runs.
killed=0
survived=0
errored=0
artifact_errors=0
SURVIVORS=()
prev_cat=""
for ((idx = 1; idx <= dispatched; idx++)); do
    stem="$RESULT_DIR/$(printf '%04d' "$idx")"
    if [ "${job_cat[idx]}" != "$prev_cat" ]; then
        echo
        echo "=== ${job_cat[idx]} ==="
        prev_cat="${job_cat[idx]}"
    fi
    result_valid=1
    if ! mutation_read_status "$idx" "$stem.status"; then
        artifact_errors=$((artifact_errors + 1))
        result_valid=0
    elif ! mutation_validate_output "$idx" "$stem.out" "$MUTATION_STATUS"; then
        artifact_errors=$((artifact_errors + 1))
        result_valid=0
    fi
    if [ "$result_valid" -ne 1 ]; then
        errored=$((errored + 1))
        continue
    fi
    cat "$stem.out"
    case "$MUTATION_STATUS" in
        killed)   killed=$((killed + 1)) ;;
        survived) survived=$((survived + 1)); SURVIVORS+=("$MUTATION_SURVIVOR") ;;
        errored)  errored=$((errored + 1)) ;;
    esac
done

shopt -s nullglob dotglob
result_artifacts=("$RESULT_DIR"/*)
shopt -u nullglob dotglob
for artifact in "${result_artifacts[@]}"; do
    base=${artifact##*/}
    if [[ $base =~ ^([0-9]{4})\.(status|out)$ ]]; then
        artifact_idx=$((10#${BASH_REMATCH[1]}))
        if [ "$artifact_idx" -ge 1 ] && [ "$artifact_idx" -le "$dispatched" ]; then
            continue
        fi
    fi
    echo "ERROR: unexpected mutation result artifact: $base" >&2
    artifact_errors=$((artifact_errors + 1))
done

echo
# Make the PIC-shell coverage explicit in the summary: a run on a host without
# XC8/gpsim silently omits the PIC mutants, and "all killed" must not be read as
# "PIC mutants passed" when they never ran. (CI's PIC job has the toolchain.)
pic_skipped=0
if [ "$PIC_GPSIM_OK" -eq 1 ]; then
    msg="PIC-shell mutants: RAN (gpsim register-level"
    if [ "$PIC_SOAK_OK" -eq 1 ]; then
        msg="$msg + libgpsim soak WDT"
    else
        msg="$msg; soak WDT skipped ($PIC_SOAK_WHY)"
        pic_skipped=$((pic_skipped + ${#PIC_SOAK_MUTATIONS[@]}))
    fi
    if [ "$PIC_TARGET_OK" -eq 1 ]; then
        msg="$msg + target aggregate"
    else
        msg="$msg; target aggregate skipped ($PIC_TARGET_WHY)"
        pic_skipped=$((pic_skipped + ${#PIC_TARGET_MUTATIONS[@]}))
    fi
    echo "$msg)"
else
    echo "PIC-shell mutants: SKIPPED ($PIC_GPSIM_WHY)"
    pic_skipped=$((pic_skipped + ${#PIC_GPSIM_MUTATIONS[@]} + ${#PIC_SOAK_MUTATIONS[@]} + ${#PIC_TARGET_MUTATIONS[@]}))
fi
if [ "$PIC10F320_TOOL_OK" -eq 1 ]; then
    echo "PIC10F320 mutants: RAN (host lanes + gpsim/libgpsim/soak)"
else
    echo "PIC10F320 mutants: host lanes RAN; target/soak SKIPPED ($PIC10F320_TOOL_WHY)"
    pic_skipped=$((pic_skipped + ${#PIC10F320_TOOL_MUTATIONS[@]}))
fi
if [ "$PIC12F675_OK" -eq 1 ]; then
    echo "PIC12F675 mutants: RAN (gpsim + target aggregate + soak)"
else
    echo "PIC12F675 mutants: SKIPPED ($PIC12F675_WHY)"
    pic_skipped=$((pic_skipped + ${#PIC12F675_MUTATIONS[@]}))
fi
# The ATtiny202 lane is all-or-nothing (one probe, one toolchain) and is counted
# separately from the PIC total so the summary keeps saying which substrate went
# unexercised rather than merging them into one anonymous number. The totals
# check below takes the COMBINED figure, since its invariant is over the whole
# inventory: every planned mutant was either dispatched or explicitly skipped.
xt_skipped=0
if [ "$XT_OK" -eq 1 ]; then
    echo "ATtiny202 mutants: RAN (yasimavr sim/lock-step/fault/soak + delay oracle)"
else
    echo "ATtiny202 mutants: SKIPPED ($XT_WHY)"
    xt_skipped=${#XT_MUTATIONS[@]}
fi
skipped=$((pic_skipped + xt_skipped))
accounting_failed=0
if ! mutation_validate_totals "$MUTATION_EXPECTED_TOTAL" "$dispatched" \
        "$skipped" "$killed" "$survived" "$errored" \
        "$worker_failures" "$artifact_errors"; then
    accounting_failed=1
fi
echo "=== mutation summary: $killed killed, $survived survived, $errored errored, $pic_skipped PIC skipped, $xt_skipped ATtiny202 skipped ==="
if [ "$survived" -ne 0 ]; then
    echo "SURVIVING MUTANTS (test suite gap -- a real fault went undetected):"
    for s in "${SURVIVORS[@]}"; do echo "  - $s"; done
fi
if [ "$survived" -ne 0 ] || [ "$errored" -ne 0 ] \
        || [ "$accounting_failed" -ne 0 ]; then
    exit 1
fi
if ! mutation_partial_result_is_allowed "$pic_skipped" "$xt_skipped" \
        "$MUTATION_ALLOW_SKIP" "$MUT_BASELINE_FAILED"; then
    echo "ERROR: mutation skips exceeded MUTATION_ALLOW_SKIP=$MUTATION_ALLOW_SKIP ($pic_skipped PIC, $xt_skipped ATtiny202)." >&2
    if [ "$MUT_BASELINE_FAILED" -eq 1 ]; then
        echo "       At least one lane skipped because its BASELINE FAILED, not because a" >&2
        echo "       tool is missing: the UNMUTATED tree did not pass a kill target. Do not" >&2
        echo "       install anything -- re-run the target named above by hand, since the" >&2
        echo "       probe discards its output. Note it may fail only INSIDE the mktemp" >&2
        echo "       sandbox, which is a copy_tree gap rather than a defect in the tree." >&2
    else
        echo "       Install the PIC toolchain/libgpsim stack (PIC lanes) and/or run" >&2
        echo "       scripts/fetch_attiny_dfp.sh + scripts/fetch_yasimavr.sh (ATtiny202" >&2
        echo "       lane), or authorize only the unavailable substrate with" >&2
        echo "       MUTATION_ALLOW_SKIP=PIC or MUTATION_ALLOW_SKIP=ATtiny202." >&2
    fi
    exit 1
fi
if [ "$skipped" -ne 0 ]; then
    echo "PARTIAL: all evaluated mutants killed, but $skipped mutant(s) were explicitly allowed to skip."
    exit 0
fi
echo "all mutants killed: the suite detects every injected fault."
exit 0
