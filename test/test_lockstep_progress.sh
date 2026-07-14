#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-lockstep-progress.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake="$work/include"
bin="$work/test_lockstep_progress"
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
#include <cstdlib>
#include <cstring>
#include <string>

using guint64 = std::uint64_t;

class TriggerObject {
public:
    virtual ~TriggerObject() = default;
    virtual void callback() = 0;
};

class Register {
    unsigned value_ = 0;
public:
    unsigned get_value() const { return value_; }
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

class IOPIN {};

class Module {
public:
    int get_pin_count() const { return 1; }
    std::string &get_pin_name(unsigned) {
        static std::string name("ra3");
        return name;
    }
    IOPIN *get_pin(unsigned) {
        static IOPIN pin;
        return &pin;
    }
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
    bool const wedge = stage != nullptr
        && ((std::strcmp(stage, "settle") == 0)
            || (std::strcmp(stage, "calibration") == 0 && now >= 30u * cycles_per_ms)
            || (std::strcmp(stage, "lockstep") == 0 && now >= 38u * cycles_per_ms));
    if (wedge) return;

    get_cycles().advance(cycles_per_ms);
    if (get_bp().hook != nullptr) get_bp().hook->callback();
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
    void set_Vth(double) {}
};

class Stimulus_Node {
public:
    explicit Stimulus_Node(const char *) {}
    template <typename T> void attach_stimulus(T *) {}
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

"$CXX" -std=c++17 -O0 -I"$fake" -DCTX_ADDR=0x20 -DF_CPU_HZ=2000000UL \
	-DLOCKSTEP_ITERS=8 "$ROOT/test/pic/test_lockstep_pic.cc" -o "$bin"

run_wedge() {
	local stage=$1 output status fatal_count
	set +e
	output=$(FAKE_GPSIM_WEDGE_AT="$stage" timeout 5 "$bin" 2>&1)
	status=$?
	set -e
	[ "$status" -eq 1 ] \
		|| { printf 'FAIL: %s wedge exited %d instead of 1: %s\n' "$stage" "$status" "$output" >&2; exit 1; }
	[[ "$output" == *"FATAL: core not advancing"* ]] \
		|| { printf 'FAIL: %s wedge omitted the fatal progress error\n' "$stage" >&2; exit 1; }
	fatal_count=$(grep -c 'FATAL: core not advancing' <<<"$output")
	[ "$fatal_count" -eq 1 ] \
		|| { printf 'FAIL: %s wedge reported %d fatal errors\n' "$stage" "$fatal_count" >&2; exit 1; }
	[[ "$output" != *"LOCK-STEP PASS"* && "$output" != *"LOCK-STEP FAIL"* ]] \
		|| { printf 'FAIL: %s wedge reached a lock-step summary\n' "$stage" >&2; exit 1; }
	if [ "$stage" = lockstep ]; then
		[[ "$output" == *"loop CLRWDT identified"* ]] \
			|| { printf 'FAIL: lockstep wedge did not reach the completion phase\n' >&2; exit 1; }
	else
		[[ "$output" != *"loop CLRWDT identified"* ]] \
			|| { printf 'FAIL: %s wedge continued after the failed run\n' "$stage" >&2; exit 1; }
	fi
	checks=$((checks + 1))
}

run_wedge settle
run_wedge calibration
run_wedge lockstep

printf 'lock-step progress failure validation: %d checks, 0 failures\n' "$checks"
