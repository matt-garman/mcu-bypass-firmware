#ifndef TEST_PIC_GPSIM_BOOTSTRAP_H
#define TEST_PIC_GPSIM_BOOTSTRAP_H

// Shared libgpsim bring-up for the four PIC harnesses -- io, lock-step, fault
// and soak -- across all three PIC targets, which build the shared harness cores
// through their own adapters.
//
// D1 factored the io/lock-step/fault BODIES into three shared cores but left
// each one carrying its own copy of the ~30-line bring-up prologue, and the soak
// was not part of that pass at all. This header owns that prologue. It is
// deliberately split into two calls rather than one, because the four harnesses
// legitimately do different work BETWEEN loading the processor and attaching the
// footswitch (io looks up its GPIO registers there, lock-step prints its banner)
// -- so consolidating does not reorder a single simulator operation in any of
// them.
//
// What stays out of here: anything a harness varies. Settle time, breakpoint
// arming, banner text and every assertion remain in the harness that owns them.

#include <cstdio>
#include <iostream>
#include <streambuf>

#include "interface.h"            // initialize_gpsim_core(), gpsim_set_bulk_mode()
#include "sim_context.h"          // CSimulationContext
#include "processor.h"            // Processor
#include "pic-processor.h"        // pic_processor
#include "modules.h"              // Module::get_pin/get_pin_name/get_pin_count
#include "ioports.h"              // IOPIN
#include "stimuli.h"              // Stimulus_Node, source_stimulus

#include "pic/find_pin_exact.h"

// RA3 is the default for the PIC10F322/PIC10F320 pair. PIC12F675's adapter
// overrides it with "gpio5" by defining FOOTSW_PIN_NAME before including this header.
#ifndef FOOTSW_PIN_NAME
#  define FOOTSW_PIN_NAME "ra3"
#endif

// gpsim narrates breakpoint/load activity on std::cout; a null streambuf
// silences it (our own output uses C stdio, so printf is unaffected).
struct NullBuf : std::streambuf { int overflow(int c) override { return c; } };
static NullBuf g_nullbuf;

// ---- Sim globals shared by every harness ------------------------------------
static pic_processor   *g_cpu      = nullptr;
static Stimulus_Node   *g_fsw_node = nullptr;
static source_stimulus *g_fsw_src  = nullptr;

// Initialize the gpsim core and load the firmware image onto the named part.
// On success g_cpu is the loaded processor. Returns false (having reported the
// reason on stderr) if the image could not be loaded -- callers must return
// non-zero rather than continue, or every later assertion reads a null CPU.
static bool gpsim_bootstrap_cpu(const char *fw_path, const char *proc_name) {
    std::cout.rdbuf(&g_nullbuf);                 // silence gpsim's console chatter
    initialize_gpsim_core();
    gpsim_set_bulk_mode(1);
    CSimulationContext *ctx = CSimulationContext::GetContext();

    Processor *p = nullptr;
    ctx->LoadProgram(fw_path, proc_name, &p, "u1");
    // LoadProgram does not always publish the processor through its out-param;
    // the active-CPU lookup is the documented fallback, not a redundant retry.
    if (p == nullptr) p = ctx->GetActiveCPU();
    if (p == nullptr) {
        fprintf(stderr, "FATAL: gpsim could not load %s on %s\n", fw_path, proc_name);
        return false;
    }
    g_cpu = static_cast<pic_processor *>(p);
    return true;
}

// Attach a driven stimulus to the footswitch pin, left RELEASED (high). Call
// after gpsim_bootstrap_cpu() has succeeded. Returns false, having reported the
// reason, if the part does not expose that pin under that exact name.
static bool gpsim_attach_footswitch(const char *pin_name, const char *proc_name) {
    IOPIN *pin = find_pin_exact(g_cpu, pin_name);
    if (pin == nullptr) {
        fprintf(stderr, "FATAL: pin %s not found on %s\n", pin_name, proc_name);
        return false;
    }
    g_fsw_src = new source_stimulus();
    g_fsw_src->set_digital();
    g_fsw_src->set_Zth(250.0);                   // dominate the pin's weak pull-up
    g_fsw_src->set_Vth(5.0);                     // released at power-on
    g_fsw_node = new Stimulus_Node("fsw");
    g_fsw_node->attach_stimulus(g_fsw_src);
    g_fsw_node->attach_stimulus(pin);
    return true;
}

// Drive the footswitch input: 1 = PRESSED (selected pin low), 0 = RELEASED (high).
// Every PIC target sees a pressed switch as a low, so a pressed stimulus is 0.0 V.
//
// A bare source_stimulus presents a constant get_Vth(), so the driven level is
// modulated directly via set_Vth -- NOT putState, which only flips an unused
// digital-state flag on the base class. Zth is set low in
// gpsim_attach_footswitch() so this source dominates the firmware's internal
// weak pull-up on the selected pin.
static void footsw_set(int pressed) {
    g_fsw_src->set_Vth(pressed ? 0.0 : 5.0);
    g_fsw_node->update();
}

#endif
