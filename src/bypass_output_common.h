// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_OUTPUT_COMMON_H__
#define BYPASS_OUTPUT_COMMON_H__


#if defined(BYPASS_MCU_PIC10F322)
#  include "bypass_pins_pic10f322.h"
#elif defined(BYPASS_MCU_AVR_XT)
#  include "bypass_pins_avr_xt.h"
#elif defined(__AVR__) || defined(BYPASS_MCU_AVR_CLASSIC)
#  include "bypass_pins_avr_classic.h"
#else
#  error "bypass: no pin map selected for this target"
#endif


#endif // BYPASS_OUTPUT_COMMON_H__
