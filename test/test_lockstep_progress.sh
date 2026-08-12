#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-lockstep-progress.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake="$work/include"
checks=0
CXX=${PIC_SOAK_CXX:-${CXX:-c++}}

if [ ! -x "$CXX" ] && ! command -v "$CXX" >/dev/null 2>&1; then
	printf 'FAIL: C++ compiler not found: %s\n' "$CXX" >&2
	exit 1
fi
command -v timeout >/dev/null 2>&1 \
	|| { printf 'FAIL: timeout is required for the lock-step progress regression\n' >&2; exit 1; }
mkdir -p "$fake"

cat > "$fake/gpsim_stubs.h" <<'EOF'
#ifndef GPSIM_STUBS_H
#define GPSIM_STUBS_H

#include <cstdint>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using guint64 = std::uint64_t;
#define G_GUINT64_FORMAT PRIu64

class TriggerObject {
public:
    virtual ~TriggerObject() = default;
    virtual void callback() = 0;
};

class Register {
    unsigned value_ = 0;
public:
    unsigned get_value() const { return value_; }
    void set_value(unsigned value) { value_ = value; }
};

class RegisterMemoryAccess {
    Register registers_[512];
public:
    Register *get_register(unsigned addr) {
        return addr < 512u ? &registers_[addr] : nullptr;
    }
};

class ProgramMemoryAccess {
public:
    unsigned get_opcode(unsigned addr) const { return addr == 1u ? 0x0064u : 0u; }
};

// The footswitch pin name is a PARAMETER, not a constant: the adapters do not
// agree on one (ra3 on the 10F32x parts, gpio5 on the PIC12F675), and the point
// of the decoys below is that each adapter resolves ITS OWN name exactly.
#ifndef FAKE_FOOTSW_PIN
#  define FAKE_FOOTSW_PIN "ra3"
#endif

class IOPIN {};

inline IOPIN *fake_pin(unsigned index) {
    static IOPIN pins[4];
    return index >= 1u && index <= 3u ? &pins[index] : nullptr;
}

class Module {
public:
    int get_pin_count() const { return 3; }
    std::string &get_pin_name(unsigned index) {
        // Two decoys that differ from the real name by a suffix and by a
        // prefix, so a substring match would pick the wrong pin.
        static std::string names[] = { "", FAKE_FOOTSW_PIN "0", "x" FAKE_FOOTSW_PIN,
                                       FAKE_FOOTSW_PIN };
        static std::string hidden(FAKE_FOOTSW_PIN "_absent");
        if (index == 3u && std::getenv("FAKE_GPSIM_HIDE_PIN") != nullptr) return hidden;
        return names[index <= 3u ? index : 0u];
    }
    IOPIN *get_pin(unsigned index) { return fake_pin(index); }
};

class Processor {
public:
    virtual ~Processor() = default;
};

class FakeCycles {
    guint64 value_ = 0;
    guint64 target_ = 0;
public:
    guint64 get() const { return value_; }
    guint64 target() const { return target_; }
    void set_break(guint64 target) { target_ = target; }
    void clear_break(guint64 target) {
        if (target_ == target) target_ = value_;
    }
    void advance(guint64 amount) {
        value_ += amount;
        if (value_ > target_) value_ = target_;
    }
};

inline FakeCycles &get_cycles() {
    static FakeCycles cycles;
    return cycles;
}

class pic_processor;

class FakeBreakpoints {
public:
    TriggerObject *hook = nullptr;
    void set_notify_break(pic_processor *, unsigned, TriggerObject *notify) { hook = notify; }
};

inline FakeBreakpoints &get_bp() {
    static FakeBreakpoints breakpoints;
    return breakpoints;
}

inline bool &fake_footswitch_pressed() {
    static bool pressed = false;
    return pressed;
}

class pic_processor : public Processor, public Module {
public:
    ProgramMemoryAccess program_memory;
    ProgramMemoryAccess *pma = &program_memory;
    RegisterMemoryAccess rma;
    void run(bool);
};

inline void pic_processor::run(bool) {
    constexpr guint64 cycles_per_ms = (F_CPU_HZ / 4UL) / 1000UL;
    char const *stage = std::getenv("FAKE_GPSIM_WEDGE_AT");
    guint64 const now = get_cycles().get();
    static unsigned stalled_resumes = 0;
    bool const wedge = stage != nullptr
        && ((std::strcmp(stage, "settle") == 0)
            || (std::strcmp(stage, "calibration") == 0 && now >= 30u * cycles_per_ms)
            || (std::strcmp(stage, "lockstep") == 0 && now >= 38u * cycles_per_ms)
            || (std::strcmp(stage, "soak") == 0 && now >= 5u * cycles_per_ms)
            || (std::strcmp(stage, "soak-liveness") == 0
                && now >= 6u * cycles_per_ms)
            || (std::strcmp(stage, "soak-late") == 0
                && now >= 200u * cycles_per_ms));
    if (wedge) {
#ifdef FAKE_SOAK_DRIVER
        constexpr unsigned max_stalled_resumes = 70u;
#else
        constexpr unsigned max_stalled_resumes = 5000u;
#endif
        if (++stalled_resumes > max_stalled_resumes) {
            std::fprintf(stderr, "FATAL: fake gpsim received excessive stalled resumes\n");
            std::exit(91);
        }
        return;
    }

    stalled_resumes = 0;
    get_cycles().advance(cycles_per_ms);
#ifdef FAKE_SOAK_DRIVER
    static bool prior_pressed = false;
    bool const pressed = fake_footswitch_pressed();
    if (pressed && !prior_pressed) {
        Register *latch = rma.get_register(PIC_REG_LATCH_ADDR);
        latch->set_value(latch->get_value() ^ PIC_REG_LED_MASK);
    }
    prior_pressed = pressed;
#endif
#ifndef FAKE_SOAK_DRIVER
    if (get_bp().hook != nullptr) get_bp().hook->callback();
#endif
}

class CSimulationContext {
    Processor *active_ = nullptr;
public:
    static CSimulationContext *GetContext() {
        static CSimulationContext context;
        return &context;
    }
    void LoadProgram(const char *, const char *, Processor **processor, const char *) {
        static pic_processor cpu;
        active_ = &cpu;
        *processor = active_;
    }
    Processor *GetActiveCPU() { return active_; }
};

class source_stimulus {
public:
    void set_digital() {}
    void set_Zth(double) {}
    void set_Vth(double voltage) { fake_footswitch_pressed() = voltage < 2.5; }
};

class Stimulus_Node {
public:
    explicit Stimulus_Node(const char *) {}
    void attach_stimulus(source_stimulus *) {}
    void attach_stimulus(IOPIN *pin) {
        if (pin != fake_pin(3u)) {
            std::fprintf(stderr, "FATAL: footswitch stimulus was not attached to exact "
                         FAKE_FOOTSW_PIN "\n");
            std::exit(1);
        }
    }
    void update() {}
};

inline void initialize_gpsim_core() {}
inline void gpsim_set_bulk_mode(int) {}

#endif
EOF

for header in glib.h interface.h sim_context.h processor.h pic-processor.h \
	modules.h ioports.h stimuli.h gpsim_time.h breakpoints.h trigger.h registers.h; do
	cat > "$fake/$header" <<'EOF'
#include "gpsim_stubs.h"
EOF
done

cat > "$fake/model_step.h" <<'EOF'
#ifndef MODEL_STEP_H
#define MODEL_STEP_H

#include <stdint.h>

#define PRESS_DEBOUNCE_WAIT 0
#define RELEASE_DEBOUNCE_WAIT 1
#define BYPASS 0
#define ENGAGED 1
#define PIN_STATE_LOW 0
#define PIN_STATE_HIGH 1
#define PRESSED_THRESH 8
#define RELEASE_THRESH 20

typedef int pin_state_t;
typedef struct {
    uint8_t program_state;
    uint8_t effect_state;
    uint8_t debounce_counter;
} debounce_context_t;
typedef struct {
    uint8_t program_state;
    uint8_t effect_state;
    uint8_t debounce_counter;
} state_t;
typedef struct {
    state_t next;
    int toggled;
} step_result_t;

static debounce_context_t debounce_init_context(pin_state_t pin) {
    debounce_context_t context = {
        (uint8_t)(pin == PIN_STATE_LOW ? RELEASE_DEBOUNCE_WAIT : PRESS_DEBOUNCE_WAIT),
        BYPASS,
        (uint8_t)(pin == PIN_STATE_LOW ? RELEASE_THRESH : 0)
    };
    return context;
}

static step_result_t step(state_t state, int) {
    step_result_t result = { state, 0 };
    return result;
}

#endif
EOF

run_wedge() {
	local label=$1 processor=$2 bin=$3 stage=$4 output status fatal_count
	set +e
	output=$(FAKE_GPSIM_WEDGE_AT="$stage" timeout 5 "$bin" 2>&1)
	status=$?
	set -e
	[ "$status" -eq 1 ] \
		|| { printf 'FAIL: %s %s wedge exited %d instead of 1: %s\n' \
			"$label" "$stage" "$status" "$output" >&2; exit 1; }
	[[ "$output" == *"proc=$processor "* ]] \
		|| { printf 'FAIL: %s %s wedge did not run the %s adapter\n' \
			"$label" "$stage" "$processor" >&2; exit 1; }
	[[ "$output" == *"FATAL: core not advancing"* ]] \
		|| { printf 'FAIL: %s %s wedge omitted the fatal progress error\n' \
			"$label" "$stage" >&2; exit 1; }
	fatal_count=$(grep -c 'FATAL: core not advancing' <<<"$output")
	[ "$fatal_count" -eq 1 ] \
		|| { printf 'FAIL: %s %s wedge reported %d fatal errors\n' \
			"$label" "$stage" "$fatal_count" >&2; exit 1; }
	[[ "$output" != *"LOCK-STEP PASS"* && "$output" != *"LOCK-STEP FAIL"* ]] \
		|| { printf 'FAIL: %s %s wedge reached a lock-step summary\n' \
			"$label" "$stage" >&2; exit 1; }
	[[ "$output" != *"PIC_TARGET_RESULT"* ]] \
		|| { printf 'FAIL: %s %s wedge reached a machine result record\n' \
			"$label" "$stage" >&2; exit 1; }
	if [ "$stage" = lockstep ]; then
		[[ "$output" == *"loop CLRWDT identified"* ]] \
			|| { printf 'FAIL: %s lockstep wedge did not reach the completion phase\n' \
				"$label" >&2; exit 1; }
	else
		[[ "$output" != *"loop CLRWDT identified"* ]] \
			|| { printf 'FAIL: %s %s wedge continued after the failed run\n' \
				"$label" "$stage" >&2; exit 1; }
	fi
	checks=$((checks + 1))
}

run_missing_pin() {
	local label=$1 processor=$2 bin=$3 pin=$4 output status
	set +e
	output=$(FAKE_GPSIM_HIDE_PIN=1 timeout 5 "$bin" 2>&1)
	status=$?
	set -e
	[ "$status" -eq 1 ] \
		|| { printf 'FAIL: %s missing-%s probe exited %d instead of 1: %s\n' \
			"$label" "$pin" "$status" "$output" >&2; exit 1; }
	[[ "$output" == *"proc=$processor "* && "$output" == *"FATAL: pin $pin not found"* ]] \
		|| { printf 'FAIL: %s did not reject decoys when exact %s was absent: %s\n' \
			"$label" "$pin" "$output" >&2; exit 1; }
	checks=$((checks + 1))
}

run_soak_wedge() {
	local label=$1 processor=$2 bin=$3 stage=$4 requested_ms=$5 completed_ms=$6
	local expected_cycles=$7 expected_advanced_ms=$8 expected_checks=$9
	local output status fail_count result
	set +e
	output=$(FAKE_GPSIM_WEDGE_AT="$stage" timeout 5 "$bin" 2>&1)
	status=$?
	set -e
	[ "$status" -eq 1 ] \
		|| { printf 'FAIL: %s %s wedge exited %d instead of 1: %s\n' \
			"$label" "$stage" "$status" "$output" >&2; exit 1; }
	[[ "$output" == *"proc=$processor "* ]] \
		|| { printf 'FAIL: %s %s wedge did not run the %s adapter\n' \
			"$label" "$stage" "$processor" >&2; exit 1; }
	fail_count=$(grep -c 'SOAK FAIL.*core not advancing' <<<"$output")
	[ "$fail_count" -eq 1 ] \
		|| { printf 'FAIL: %s %s wedge reported %d progress failures\n' \
			"$label" "$stage" "$fail_count" >&2; exit 1; }
	[[ "$output" != *"excessive stalled resumes"* && "$output" != *"SOAK PASS"* ]] \
		|| { printf 'FAIL: %s %s wedge continued after the resume cap\n' \
			"$label" "$stage" >&2; exit 1; }
	result="SOAK_RESULT format=1 status=fail combination=${label}-wedge duration_ms=$completed_ms liveness_interval_ms=1 checks=$expected_checks failures=1 watchdog_failures=0 liveness_failures=0"
	[ "$(grep -c '^SOAK_RESULT ' <<<"$output")" -eq 1 ] \
		&& grep -Fxq "$result" <<<"$output" \
		|| { printf 'FAIL: %s %s wedge omitted its exact short-duration result: %s\n' \
			"$label" "$stage" "$output" >&2; exit 1; }
	[[ "$output" == *"SOAK FAIL: $completed_ms/$requested_ms requested ms completed; $expected_cycles cycles ($expected_advanced_ms ms) advanced."* ]] \
		|| { printf 'FAIL: %s %s wedge omitted actual cycle/time evidence\n' \
			"$label" "$stage" >&2; exit 1; }
	! grep -Eq "^SOAK_RESULT .*duration_ms=${requested_ms}([[:space:]]|$)" <<<"$output" \
		|| { printf 'FAIL: %s %s wedge claimed the full requested duration\n' \
			"$label" "$stage" >&2; exit 1; }
	checks=$((checks + 1))
}

run_soak_control() {
	local label=$1 processor=$2 bin=$3 requested_ms=$4 output result
	output=$(timeout 5 "$bin" 2>&1) \
		|| { printf 'FAIL: %s healthy soak control failed: %s\n' \
			"$label" "$output" >&2; exit 1; }
	[[ "$output" == *"proc=$processor "* ]] \
		|| { printf 'FAIL: %s healthy soak did not run the %s adapter\n' \
			"$label" "$processor" >&2; exit 1; }
	[ "$(grep -c "^SOAK PASS: $requested_ms ms " <<<"$output")" -eq 1 ] \
		|| { printf 'FAIL: %s healthy soak omitted its exact-duration PASS summary\n' \
			"$label" >&2; exit 1; }
	result="SOAK_RESULT format=1 status=pass combination=${label}-wedge duration_ms=$requested_ms liveness_interval_ms=1 checks=$requested_ms failures=0 watchdog_failures=0 liveness_failures=0"
	[ "$(grep -c '^SOAK_RESULT ' <<<"$output")" -eq 1 ] \
		&& grep -Fxq "$result" <<<"$output" \
		|| { printf 'FAIL: %s healthy soak omitted its release-compatible result: %s\n' \
			"$label" "$output" >&2; exit 1; }
	[[ "$output" != *"SOAK FAIL"* ]] \
		|| { printf 'FAIL: %s healthy soak also reported failure\n' "$label" >&2; exit 1; }
	checks=$((checks + 1))
}

# $1 label, $2 adapter source, $3 gpsim processor, $4 footswitch pin name, $5 FOSC.
#
# The pin is passed to the STUB, never to the adapter: each adapter must reach
# its own pin name through its own device map (the PIC12F675's comes from
# test/pic/pic12f675_regs.h), and this gate proves the name it actually asks for
# is the one it resolves. Defining it for the adapter would prove nothing.
run_adapter() {
	local label=$1 source=$2 processor=$3 pin=$4 fosc=$5
	local bin="$work/test_lockstep_progress_$processor"
	# FW_PATH is required rather than defaulted (test_lockstep_pic_core.h), so
	# this gate states its own instead of inheriting a part adapter's. The value
	# is never opened: the fake CSimulationContext::LoadProgram above ignores its
	# path argument entirely, because what is under test here is the harness's
	# failure reporting, not image loading. Naming that in the value keeps a
	# reader from hunting for a file that was never meant to exist.
	"$CXX" -std=c++17 -O0 -I"$fake" -I"$ROOT/test" \
		-DCTX_ADDR=0x20 -DF_CPU_HZ="$fosc" -DFAKE_FOOTSW_PIN="\"$pin\"" \
		-DFW_PATH='"<never loaded: fake gpsim ignores the image path>"' \
		-DLOCKSTEP_ITERS=8 "$ROOT/$source" -o "$bin"
	run_missing_pin "$label" "$processor" "$bin" "$pin"
	run_wedge "$label" "$processor" "$bin" settle
	run_wedge "$label" "$processor" "$bin" calibration
	run_wedge "$label" "$processor" "$bin" lockstep
}

run_soak_adapter() {
	local label=$1 source=$2 processor=$3 pin=$4 fosc=$5 shadow_def=$6
	local bin="$work/test_soak_progress_$processor" requested_ms=10 cycles_per_ms tick_us
	if [ "$fosc" = 4000000UL ]; then tick_us=1024; else tick_us=1000; fi
	"$CXX" -std=c++17 -O0 -I"$fake" -I"$ROOT/test" \
		-DFAKE_SOAK_DRIVER=1 -DFAKE_FOOTSW_PIN="\"$pin\"" \
		-DFW_PATH='"<fake gpsim image>"' \
		-DPROC_NAME="\"$processor\"" -DF_CPU_HZ="$fosc" $shadow_def \
		-DSOAK_DURATION_MS="$requested_ms" \
		-DSOAK_LIVENESS_INTERVAL_MS=1 \
		-DSOAK_PROGRESS_INTERVAL_MS="$requested_ms" \
		-DSOAK_COMBINATION_NAME="\"${label}-wedge\"" \
		-DSOAK_TICK_US="${tick_us}u" -DSOAK_ACTUATION_BLOCK_MS=0u \
		"$ROOT/$source" -o "$bin"
	if [ "$fosc" = 4000000UL ]; then cycles_per_ms=1000; else cycles_per_ms=500; fi
	run_soak_control "$label" "$processor" "$bin" "$requested_ms"
	run_soak_wedge "$label" "$processor" "$bin" settle "$requested_ms" 0 0 0.000 1
	run_soak_wedge "$label" "$processor" "$bin" soak "$requested_ms" 0 \
		$((5 * cycles_per_ms)) 5.000 1
	run_soak_wedge "$label" "$processor" "$bin" soak-liveness "$requested_ms" 0 \
		$((6 * cycles_per_ms)) 6.000 1
	run_soak_wedge "$label" "$processor" "$bin" soak-late "$requested_ms" 1 \
		$((200 * cycles_per_ms)) 200.000 2
}

run_adapter PIC10F322 test/pic/test_lockstep_pic.cc p10f322 ra3 2000000UL
run_adapter PIC10F320 test/pic10f320/gpsim/test_lockstep_pic.cc p10f320 ra3 2000000UL
run_adapter PIC12F675 test/pic/test_lockstep_pic12f675.cc p12f675 gpio5 4000000UL

run_soak_adapter PIC10F322 test/pic/test_soak_pic.cc p10f322 ra3 2000000UL ''
run_soak_adapter PIC10F320 test/pic/test_soak_pic.cc p10f320 ra3 2000000UL ''
run_soak_adapter PIC12F675 test/pic/test_soak_pic12f675.cc p12f675 gpio5 4000000UL \
	'-DPIC_SHADOW_ADDR=0x20'

printf 'PIC simulator progress failure validation: %d checks, 0 failures\n' "$checks"
