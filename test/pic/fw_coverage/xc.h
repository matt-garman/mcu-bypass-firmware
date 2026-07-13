// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_PIC_FW_COVERAGE_XC_H
#define BYPASS_PIC_FW_COVERAGE_XC_H

#include <stdint.h>

uint8_t *bypass_lata_access(void);
#define LATA (*bypass_lata_access())

extern uint8_t PORTA;
extern uint8_t TRISA;
extern uint8_t ANSELA;
extern uint8_t WPUA;
extern uint8_t PR2;
extern uint8_t T2CON;

typedef struct { unsigned nWPUEN : 1; } OPTION_REGbits_t;
typedef struct { unsigned IRCF   : 3; } OSCCONbits_t;
typedef struct { unsigned WDTPS  : 5; } WDTCONbits_t;
typedef struct { unsigned GIE    : 1; } INTCONbits_t;
extern OPTION_REGbits_t OPTION_REGbits;
extern OSCCONbits_t     OSCCONbits;
extern WDTCONbits_t     WDTCONbits;
extern volatile INTCONbits_t INTCONbits;

typedef struct { unsigned TMR2IF : 1; } PIR1bits_t;
PIR1bits_t *bypass_pir1(void);
#define PIR1bits (*bypass_pir1())

void bypass_coverage_on_clrwdt(void);
#define CLRWDT() bypass_coverage_on_clrwdt()

void bypass_on_delay_ms(unsigned ms);
#define __delay_ms(x) bypass_on_delay_ms((unsigned)(x))

#define _PORTA_RA0_POSN 0
#define _PORTA_RA1_POSN 1
#define _PORTA_RA2_POSN 2
#define _PORTA_RA3_POSN 3

#endif
