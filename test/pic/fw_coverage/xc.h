// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_PIC_FW_COVERAGE_XC_H
#define BYPASS_PIC_FW_COVERAGE_XC_H

#include <stdint.h>

#if (defined(BYPASS_MCU_PIC10F322) + defined(BYPASS_MCU_PIC12F675)) != 1
#  error "select exactly one PIC coverage target"
#endif

#if defined(BYPASS_MCU_PIC12F675)

uint8_t *bypass_gpio_access(void);
#define GPIO (*bypass_gpio_access())

extern uint8_t TRISIO;
extern uint8_t ANSEL;
extern uint8_t WPU;
extern uint8_t CMCON;
extern uint8_t OSCCAL;
extern uint8_t TMR0;

typedef union {
    uint8_t value;
    struct {
        unsigned char PS     : 3;
        unsigned char PSA    : 1;
        unsigned char T0SE   : 1;
        unsigned char T0CS   : 1;
        unsigned char INTEDG : 1;
        unsigned char nGPPU  : 1;
    } bits;
} bypass_option_reg_t;
extern bypass_option_reg_t bypass_option_reg;
#define OPTION_REG     (bypass_option_reg.value)
#define OPTION_REGbits (bypass_option_reg.bits)

typedef union {
    uint8_t value;
    struct {
        unsigned char ADON : 1;
        unsigned char rest : 7;
    } bits;
} bypass_adcon0_reg_t;
extern bypass_adcon0_reg_t bypass_adcon0_reg;
#define ADCON0     (bypass_adcon0_reg.value)
#define ADCON0bits (bypass_adcon0_reg.bits)

typedef struct {
    unsigned char T0IF : 1;
    unsigned char GIE  : 1;
} INTCONbits_t;
volatile INTCONbits_t *bypass_intcon(void);
#define INTCONbits (*bypass_intcon())

_Static_assert(sizeof(bypass_option_reg_t) == 1u,
               "OPTION_REG mock must occupy one byte");
_Static_assert(sizeof(bypass_adcon0_reg_t) == 1u,
               "ADCON0 mock must occupy one byte");

#define _GPIO_GP0_POSN 0
#define _GPIO_GP1_POSN 1
#define _GPIO_GP2_POSN 2
#define _GPIO_GP3_POSN 3
#define _GPIO_GP4_POSN 4
#define _GPIO_GP5_POSN 5

#else

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

#define _PORTA_RA0_POSN 0
#define _PORTA_RA1_POSN 1
#define _PORTA_RA2_POSN 2
#define _PORTA_RA3_POSN 3

#endif

void bypass_coverage_on_clrwdt(void);
#define CLRWDT() bypass_coverage_on_clrwdt()

void bypass_on_delay_ms(unsigned ms);
#define __delay_ms(x) bypass_on_delay_ms((unsigned)(x))

#endif
