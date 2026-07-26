// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Reference-model debounce thresholds (host-only; not compiled into firmware).
//
// These MUST match the firmware's values in ../../bypass_mcu_pic10f320.c. There
// is no shared header to enforce that statically (the firmware deliberately
// defines its constants inline, collapsed into a single file), so the match is
// enforced DYNAMICALLY by the equivalence test (`make test-equiv`): it runs the
// real firmware against this model over exhaustive/random stimulus, and any
// threshold mismatch makes their toggle traces diverge and fails the test.
//
// This header exists only to satisfy bypass_pure.c's #include "bypass_config.h"
// when the vendored model is compiled on the host.

#ifndef BYPASS_CONFIG_H__
#define BYPASS_CONFIG_H__

// number of HIGH footswitch reads to be considered release-debounced (lock-out)
#define RELEASE_THRESH (25U)

// number of LOW footswitch reads to be considered press-debounced
#define PRESSED_THRESH (8U)

#endif // BYPASS_CONFIG_H__
