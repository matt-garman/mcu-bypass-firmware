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

readonly MUTATION_EXPECTED_CORE=24
readonly MUTATION_EXPECTED_XT=19
readonly MUTATION_EXPECTED_PIC_GPSIM=6
readonly MUTATION_EXPECTED_PIC_TARGET=8
readonly MUTATION_EXPECTED_PIC_SOAK=1
readonly MUTATION_EXPECTED_PIC320_HOST=29
readonly MUTATION_EXPECTED_PIC320_TOOL=11
readonly MUTATION_EXPECTED_TOTAL=98

# PIC build/test knobs (mirror the Makefile defaults; override via env). Used by
# the PIC-shell mutants and their toolchain probe below.
GPSIM="${GPSIM:-gpsim}"
MUTATION_MAKE="${MUTATION_MAKE:-make}"
PIC_SOAK_CXX="${PIC_SOAK_CXX:-c++}"
PIC10F320_SOAK_CXX="${PIC10F320_SOAK_CXX:-$PIC_SOAK_CXX}"
export PIC_SOAK_CXX PIC10F320_SOAK_CXX

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
PIC10F322_MUTATION_VARIANT="${PIC10F322_MUTATION_VARIANT:-cd4053_simple}"
resolve_pic10f322_mutation_hex() {
    local dir images matched
    dir=$("$MUTATION_MAKE" -s -C "$PROJ_DIR" print-PIC10F322_BUILD_DIR) || return 1
    images=$("$MUTATION_MAKE" -s -C "$PROJ_DIR" print-PIC10F322_RELEASE_IMAGES) || return 1
    [ -n "$dir" ] && [ -n "$images" ] || return 1
    matched=$(printf '%s\n' $images | grep -c -- "-${PIC10F322_MUTATION_VARIANT}\.hex$")
    [ "$matched" -eq 1 ] || return 1
    printf '%s/%s\n' "$dir" \
        "$(printf '%s\n' $images | grep -- "-${PIC10F322_MUTATION_VARIANT}\.hex$")"
}
if ! PIC10F322_MUTATION_HEX=$(resolve_pic10f322_mutation_hex); then
    echo "ERROR: cannot resolve the PIC10F322 ${PIC10F322_MUTATION_VARIANT} image" \
         "from the Makefile; PIC10F322_RELEASE_IMAGES names no such output stage" >&2
    exit 1
fi
readonly PIC10F322_MUTATION_HEX
PIC_SOAK_GPSIM_INC="${PIC_SOAK_GPSIM_INC:-/usr/include/gpsim}"
PIC10F320_SOAK_GPSIM_INC="${PIC10F320_SOAK_GPSIM_INC:-$PIC_SOAK_GPSIM_INC}"
# Wall-clock ceiling on a single mutant checker. Every mutant runs under this;
# see mutation_bounded below.
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
MUTATION_TIMEOUT_S="${MUTATION_TIMEOUT_S:-900}"
# SIGTERM at the deadline, SIGKILL 10 s later for anything that ignores it.
# timeout(1) runs the command in its own process group and signals the group, so
# make's children go down with it rather than being orphaned into the background.
#
# The exit status matters as much as the bound: expiry yields 124, which
# mutation_accounting.sh classifies as an infrastructure error, so a hung mutant
# is reported as ERROR. Without that classification a hang would exit nonzero and
# be recorded as KILLED -- a clean-looking run that measured nothing.
mutation_bounded() {
    timeout -k 10 "$MUTATION_TIMEOUT_S" "$@"
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
active_pids=()
launching_pid=0
cleanup_mutation_run() {
    local pid attempt alive
    local -a groups=()
    local -A seen_groups=()
    for pid in "${active_pids[@]}" "$launching_pid"; do
        [ "$pid" -eq 0 ] && continue
        if [[ -z ${seen_groups["$pid"]+x} ]]; then
            seen_groups["$pid"]=1
            groups+=("$pid")
        fi
    done
    # `jobs -pr` closes the signal window between `run_mutant &` and assigning
    # `$!` to launching_pid: every unreaped worker group is still discoverable.
    while read -r pid; do
        [ -n "$pid" ] || continue
        if [[ -z ${seen_groups["$pid"]+x} ]]; then
            seen_groups["$pid"]=1
            groups+=("$pid")
        fi
    done < <(jobs -pr)
    for pid in "${groups[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
    for ((attempt = 0; attempt < 20; attempt++)); do
        alive=0
        for pid in "${groups[@]}"; do
            if kill -0 -- "-$pid" 2>/dev/null; then alive=1; break; fi
        done
        [ "$alive" -eq 1 ] || break
        sleep 0.05
    done
    for pid in "${groups[@]}"; do kill -KILL -- "-$pid" 2>/dev/null || true; done
    for pid in "${groups[@]}"; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$RESULT_DIR"
}
mutation_signal_exit() {
    local code=$1
    trap - HUP INT TERM
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
    # Briefly enable job control so this worker and every descendant Make process
    # receive their own process group. Disable it before waiting to suppress job
    # notifications in the deterministic mutation log.
    set -m
    run_mutant "$@" &
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
    if ! SELFTEST_DIR="$(mktemp -d)"; then
        echo "ERROR: could not create mutation self-test sandbox" >&2
        exit 1
    fi
    if ! copy_tree "$SELFTEST_DIR" || ! validate_pic10f320_sandbox "$SELFTEST_DIR"; then
        rm -rf "$SELFTEST_DIR"
        exit 1
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
        make|pictarget|avrxt) [ -n "$arg" ] ;;
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
#   $2 kind : make | picgpsim | picsoak | pictarget
#   $3 arg  : make target (kind=make), PIC variant (kind=pictarget), ignored otherwise
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
    if ! work="$(mktemp -d)"; then
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

    # Run the mapped checker. Killed == nonzero exit (a build OR a test failure
    # both count as "the suite did not silently accept the fault").
    local label rc
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
                YASIMAVR_VENV="$xt_yasimavr_venv_abs" >/dev/null 2>&1; rc=$?
            ;;
        *)
            publish_mutation_result "$stem" errored \
                "[$idx] ERROR  unknown mutation checker kind '$kind': $desc"
            local publish_rc=$?
            rm -rf "$work" || true
            return "$publish_rc"
            ;;
    esac

    if mutation_checker_status_is_infrastructure_error "$rc"; then
        publish_mutation_result "$stem" errored \
            "[$idx] ERROR  checker infrastructure status $rc ($label): $desc"
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
"src/bypass_mcu_pic10f322.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	cd4053_simple	PIC pull-up init regressed to read-modify-write; exact WPUA state can preserve unexpected output-pin latches"
"src/bypass_mcu_pic10f322.c	s@wpua_latches == (uint8_t)(1U << FOOTSW_PIN)@0U != (wpua_latches \& (uint8_t)(1U << FOOTSW_PIN))@	cd4053_simple	PIC exact WPUA guard weakened to RA3-present only; extra RA0..RA2 latches go undetected"
"src/bypass_mcu_pic10f322.c	s@(actual_direction_mask == expected_direction_mask)@(1U != 0U)@	cd4053_simple	PIC exact-TRISA predicate removed: spare RA2 direction corruption evades the remaining required-subset check"
"src/bypass_mcu_pic10f322.c	s@LATA & (uint8_t)BYPASS_OUTPUT_DDR_MASK@LATA \& (uint8_t)0x03U@	cd4053_simple	PIC output-latch mask omits RA2; an unexpected high spare/control/coil latch goes undetected"
"src/bypass_mcu_pic10f322.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	cd4053_simple	PIC ANSELA sanity mask narrowed to RA0 only; RA1/RA2 analog re-selection undetected"
"src/bypass_output_cd4053_with_mute.c	s@hw_led_pin_set_low();          // dark status LED@hw_pin_set_high(CD4053_CTL1);  // MUTANT: reassert ENGAGED at startup\\n    hw_pin_set_high(CD4053_CTL2);\\n\\n    hw_led_pin_set_low();          // dark status LED@	cd4053_with_mute	PIC cd4053_with_mute startup reasserts ENGAGED before MUTE; target I/O startup trace catches it"
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	cd4053_with_mute	PIC cd4053_with_mute pre-switch mute window shortened; target I/O pulse-width check catches it"
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	tq2_l2_5v_relay	PIC relay coil pulse shortened below datasheet minimum; target I/O pulse-width check catches it"
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
"src/bypass_mcu_pic10f320.c	/void main(void)/,\$s@        set_relay_coils_low(); // reassert the safe idle state every serviced iteration@@	PIC10F320_VARIANT=tq2_l2_5v_relay pic10f320-test-fault-host	FW relay idle coil-low re-drive removed; host latch injections remain energized after the next serviced iteration"
"src/bypass_mcu_pic10f320.c	/void main(void)/,\$s@        set_relay_coils_low(); // reassert the safe idle state every serviced iteration@        hw_relay_reset_pin_set_low(); // MUTANT: clear RESET only@	PIC10F320_VARIANT=tq2_l2_5v_relay pic10f320-test-fault-host	FW relay idle re-drive clears RESET only; an injected SET coil remains energized"
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
"src/bypass_mcu_pic10f320.c	/void main(void)/,\$s@        set_relay_coils_low(); // reassert the safe idle state every serviced iteration@@	PIC10F320_VARIANT=tq2_l2_5v_relay PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay pic10f320-test-target	TARGET relay idle coil-low re-drive removed; physical PORTA injections remain energized past the next serviced iteration"
"src/bypass_mcu_pic10f320.c	/void main(void)/,\$s@        set_relay_coils_low(); // reassert the safe idle state every serviced iteration@        hw_relay_set_pin_set_low(); // MUTANT: clear SET only@	PIC10F320_VARIANT=tq2_l2_5v_relay PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay pic10f320-test-target	TARGET relay idle re-drive clears SET only; an injected RESET coil remains physically energized"
"src/bypass_mcu_pic10f320.c	/void main(void)/,\$s@CLRWDT();@(void)0; /* MUTANT: no main-loop WDT pet */@	PIC10F320_VARIANT=cd4053_simple PIC10F320_SOAK_DURATION_MS=$PIC_SOAK_MUT_MS PIC10F320_SOAK_LIVENESS_INTERVAL_MS=$PIC_SOAK_MUT_MS pic10f320-test-soak	SOAK main-loop WDT pet removed; reset notifier catches the un-pet watchdog within the short mutation window"
)

PIC_SOAK_MUTATIONS=(
"src/bypass_mcu_pic10f322.c	s@{ CLRWDT(); }@{ (void)0; /* MUTANT: no WDT pet */ }@	PIC WDT pet (CLRWDT) removed; soak reset counter trips within ~1s of an un-pet WDT"
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
# -- observable behaviour: killed by the functional + output-trace driver ------
"src/bypass_mcu_avr_xt.c	s@void hw_led_pin_set_high(void) { PORTA.OUTSET = (uint8_t)(1U << LED_PIN); }@void hw_led_pin_set_high(void) { PORTA.OUTCLR = (uint8_t)(1U << LED_PIN); }@	XT_SIM_VARIANT=cd4053_simple attiny202-sim	XT set_engaged LED inverted (OUTSET becomes OUTCLR; PA1 never lights); toggle assertions catch it"
"src/bypass_mcu_avr_xt.c	s@void hw_led_pin_set_low(void)  { PORTA.OUTCLR = (uint8_t)(1U << LED_PIN); }@void hw_led_pin_set_low(void)  { PORTA.OUTSET = (uint8_t)(1U << LED_PIN); }@	XT_SIM_VARIANT=cd4053_simple attiny202-sim	XT set_bypass LED clear inverted (PA1 stuck lit); boot-dark and alternating-toggle checks catch it"
"src/bypass_mcu_avr_xt.c	s@(0U == (PORTA.IN & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA.IN \& (uint8_t)(1U << FOOTSW_PIN)))@	XT_SIM_VARIANT=cd4053_simple attiny202-sim	XT footswitch read polarity inverted (PA7 sense flipped -> toggles on release, not press)"
"src/bypass_mcu_avr_xt.c	s@void hw_pin_set_high(uint8_t const pin) { PORTA.OUTSET = (uint8_t)(1U << pin); }@void hw_pin_set_high(uint8_t const pin) { PORTA.OUTCLR = (uint8_t)(1U << pin); }@	XT_SIM_VARIANT=tq2_l2_5v_relay attiny202-sim	XT control-pin drive inverted (coil/CTL bit never set); PA2/PA3 transition trace catches it"
"src/bypass_mcu_avr_xt.c	s@    PORTA.OUTCLR = output_mask; // selected outputs -> low latch@    PORTA.OUTSET = output_mask; // MUTANT: outputs latched HIGH before DIR@	XT_SIM_VARIANT=tq2_l2_5v_relay attiny202-sim	XT output pins latched high before the DIR write (glitch: both relay coils driven at startup); startup trace catches the unsafe pre-config high"
# -- internal trajectory: killed by the ctx_-vs-model lock-step co-simulation --
"src/bypass_mcu_avr_xt.c	s@ctx_.debounce_counter = res.lockout_value;@(void)0; /* MUTANT: lockout reload dropped */@	XT_SIM_VARIANT=cd4053_simple attiny202-lockstep	XT anti-retrigger lockout reload dropped; counter keeps its integrated value instead of RELEASE_THRESH"
"src/bypass_mcu_avr_xt.c	s@ctx_.program_state = res.program_state;@(void)0; /* MUTANT: program_state write-back dropped */@	XT_SIM_VARIANT=cd4053_simple attiny202-lockstep	XT program_state write-back dropped; the state machine never advances out of PRESS_DEBOUNCE_WAIT"
"src/bypass_mcu_avr_xt.c	s@ctx_.effect_state  = res.effect_state;@(void)0; /* MUTANT: effect_state write-back dropped */@	XT_SIM_VARIANT=cd4053_simple attiny202-lockstep	XT effect_state write-back dropped; ctx_ diverges from the model even where the LED briefly agrees"
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
validate_mutation_inventory XT_MUTATIONS ATtiny202 "$MUTATION_EXPECTED_XT" 4 || exit 2
inventory_total=$((${#MUTATIONS[@]} + ${#XT_MUTATIONS[@]} \
    + ${#PIC_GPSIM_MUTATIONS[@]} \
    + ${#PIC_TARGET_MUTATIONS[@]} + ${#PIC_SOAK_MUTATIONS[@]} \
    + ${#PIC10F320_HOST_MUTATIONS[@]} + ${#PIC10F320_TOOL_MUTATIONS[@]}))
mutation_require_count total "$MUTATION_EXPECTED_TOTAL" "$inventory_total" || exit 2

collect_baseline_targets() {
    local array_name=$1 label=$2 field_count=$3 target_index=$4 output_name=$5
    local entry target
    local -n entries=$array_name output=$output_name
    local -A seen=()
    output=()
    for entry in "${entries[@]}"; do
        mutation_parse_record "$label baseline" "$field_count" "$entry" || return 1
        target=${MUTATION_RECORD_FIELDS[target_index]}
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
collect_baseline_targets MUTATIONS core/AVR 4 2 CORE_BASE_TARGETS || exit 2
collect_baseline_targets PIC10F320_HOST_MUTATIONS PIC10F320-host 4 2 \
    PIC10F320_HOST_BASE_TARGETS || exit 2
collect_baseline_targets PIC10F320_TOOL_MUTATIONS PIC10F320-tool 4 2 \
    PIC10F320_BASE_TARGETS || exit 2

HOST_BASE_TARGETS=()
declare -A host_baseline_seen=()
for target in "${CORE_BASE_TARGETS[@]}" "${PIC10F320_HOST_BASE_TARGETS[@]}"; do
    if [[ -z ${host_baseline_seen["$target"]+x} ]]; then
        host_baseline_seen["$target"]=1
        HOST_BASE_TARGETS+=("$target")
    fi
done

if [ "$SANDBOX_SELFTEST_DONE" -eq 1 ]; then
    # Fully provisioned, then the two partial shapes the skip accounting can
    # produce: every simulator absent (only the 53 host mutants dispatch), and
    # the ATtiny202 lane alone absent. The second is the case this file's
    # combined `skipped` exists for -- a box with the PIC stack but no vendored
    # DFP/yasimavr -- so the totals check must accept a skip that is not PIC's.
    mutation_validate_totals 98 98 0 98 0 0 0 0 || exit 1
    mutation_validate_totals 98 53 45 53 0 0 0 0 || exit 1
    mutation_validate_totals 98 79 19 79 0 0 0 0 || exit 1
    if mutation_validate_totals 98 52 45 52 0 0 0 0 >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted a dropped dispatch" >&2; exit 1
    fi
    if mutation_validate_totals 98 53 45 52 0 0 0 0 >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted a missing result" >&2; exit 1
    fi
    if mutation_validate_totals 98 53 45 53 0 0 1 0 >/dev/null 2>&1; then
        echo "ERROR: mutation accounting accepted a failed worker" >&2; exit 1
    fi
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
    MUTATION_TIMEOUT_S=1 mutation_bounded sleep 30 >/dev/null 2>&1 || mutation_selftest_rc=$?
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
    MUTATION_TIMEOUT_S=30 mutation_bounded true >/dev/null 2>&1 || {
        echo "ERROR: mutation_bounded failed a command that completed in time" >&2
        exit 1
    }
    if mutation_checker_status_is_infrastructure_error 1; then
        echo "ERROR: mutation accounting rejected an ordinary mutation kill status" >&2
        exit 1
    fi
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

    # A failed baseline build must dominate a stale, apparently usable HEX. Use
    # an ordinary nonzero status (which is a legitimate kill for a mutant) to
    # prove it is treated as baseline infrastructure here, before dispatch.
    fake_pic_make="$RESULT_DIR/fake-pic-baseline-make"
    fake_gpsim="$RESULT_DIR/fake-gpsim"
    stale_hex_root="$RESULT_DIR/pic-baseline"
    gpsim_log="$RESULT_DIR/fake-gpsim.log"
    pic_probe_log="$RESULT_DIR/pic-baseline.log"
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
    chmod 750 "$fake_pic_make" "$fake_gpsim"
    mkdir -p "$stale_hex_root"
    PIC_GPSIM_OK=1
    PIC_GPSIM_WHY="tools absent"
    MUT_BASELINE_FAILED=0
    pic_probe_rc=0
    MUTATION_MAKE="$fake_pic_make" \
        PIC_BASELINE_STALE_HEX="$PIC10F322_MUTATION_HEX" \
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
    echo "mutation sandbox/accounting validation: 37 checks, 0 failures"
    exit 0
fi

# Sanity: the unmutated tree must PASS every target we rely on, otherwise a
# "killed" result is meaningless (it would just mean the baseline is broken).
# Baseline-check EVERY distinct kill target the MUTATIONS list uses -- not just
# test-sim-attiny13a -- so a mutant killed by e.g. test-model-check can never be a false
# kill against a baseline that was never verified. (The PIC-shell mutants have
# their own baseline probe below, since their tools may be absent.)
echo "=== mutation testing: baseline sanity check ==="
if ! BASE_DIR="$(mktemp -d)"; then
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
    job_specs+=("$core_cat$US""make$US$target$US$file$US$sed_expr$US$desc")
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
if ! PIC_BASE="$(mktemp -d)"; then
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
if ! P320_BASE="$(mktemp -d)"; then
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

if mutation_bounded "$MUTATION_MAKE" -C "$P320_BASE" pic10f320-variants >/dev/null 2>&1 \
   && command -v "$GPSIM" >/dev/null 2>&1 \
   && command -v "$PIC10F320_SOAK_CXX" >/dev/null 2>&1 \
   && [ -f "$PIC10F320_SOAK_GPSIM_INC/sim_context.h" ] \
   && pkg-config --exists glib-2.0 2>/dev/null; then
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
else
    echo "XC8/gpsim/libgpsim absent -> PIC10F320 tool mutants SKIPPED"
fi
rm -rf "$P320_BASE"

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
XT_BASE="$(mktemp -d)"
copy_tree "$XT_BASE"
if ! validate_avr_xt_sandbox "$XT_BASE"; then
    rm -rf "$XT_BASE"
    exit 2
fi
echo "AVR-XT mutation sandbox files: PASS"

if [ -f "$xt_dfp_abs/gcc/dev/$XT_MCU/device-specs/specs-$XT_MCU" ] \
   && [ -x "$xt_yasimavr_venv_abs/bin/python" ] \
   && "$xt_yasimavr_venv_abs/bin/python" -c "import yasimavr" >/dev/null 2>&1; then
    XT_BASELINES_OK=1
    while IFS= read -r target; do
        # Intentional word splitting: each field is optional VAR=value
        # assignments followed by one Make target, never shell metacharacters.
        if mutation_bounded "$MUTATION_MAKE" -C "$XT_BASE" $target \
                XT_DFP="$xt_dfp_abs" \
                YASIMAVR_VENV="$xt_yasimavr_venv_abs" >/dev/null 2>&1; then
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
    echo "ATtiny_DFP and/or patched yasimavr absent -> ATtiny202 mutants SKIPPED"
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
if [ "$skipped" -ne 0 ] && [ "$MUTATION_ALLOW_SKIP" -ne 1 ]; then
    echo "ERROR: $skipped mutant(s) skipped; complete mutation gate did not run." >&2
    if [ "$MUT_BASELINE_FAILED" -eq 1 ]; then
        echo "       At least one lane skipped because its BASELINE FAILED, not because a" >&2
        echo "       tool is missing: the UNMUTATED tree did not pass a kill target. Do not" >&2
        echo "       install anything -- re-run the target named above by hand, since the" >&2
        echo "       probe discards its output. Note it may fail only INSIDE the mktemp" >&2
        echo "       sandbox, which is a copy_tree gap rather than a defect in the tree." >&2
    else
        echo "       Install the PIC toolchain/libgpsim stack (PIC lanes) and/or run" >&2
        echo "       scripts/fetch_attiny_dfp.sh + scripts/fetch_yasimavr.sh (ATtiny202" >&2
        echo "       lane), or set MUTATION_ALLOW_SKIP=1 for an explicitly partial run." >&2
    fi
    exit 1
fi
if [ "$skipped" -ne 0 ]; then
    echo "PARTIAL: all evaluated mutants killed, but $skipped mutant(s) were explicitly allowed to skip."
    exit 0
fi
echo "all mutants killed: the suite detects every injected fault."
exit 0
