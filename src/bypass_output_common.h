// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.

#ifndef BYPASS_OUTPUT_COMMON_H__
#define BYPASS_OUTPUT_COMMON_H__


#if defined(BYPASS_MCU_PIC10F32X)
#  include "bypass_pins_pic10f32x.h"
#elif defined(__AVR__) || defined(BYPASS_MCU_AVR_CLASSIC)
#  include "bypass_pins_avr_classic.h"
#else
#  error "bypass: no pin map selected for this target"
#endif


#endif // BYPASS_OUTPUT_COMMON_H__
