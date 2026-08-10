// PIC10F32x CONFIG-word decode table for test_config_pic_core.h.
//
// The CONFIG address, layout, implemented-bit mask and expected word are
// IDENTICAL on the PIC10F322 and PIC10F320, so one table serves both chips; only
// the printed device name differs, and that arrives as PIC_DEVICE_NAME.
//
// The CONFIG word lives at PROGRAM-MEMORY WORD address 0x2007. Implemented bits
// are 0x1FFF (bits 0..12); the unimplemented upper bits read as 1, so the device
// default is 0x3FFF and the only "extra" set bit in a built image is bit 13
// (0x2000). Field masks/values are taken verbatim from the DFP cfgdata for this
// exact device -- `CWORD:2007:1FFF:3FFF:CONFIG`.
//
// References:
//   PIC10(L)F320/322 datasheet DS40001585, "Configuration Word".
//   DFP cfgdata: <DFP>/xc8/pic/dat/cfgdata/10f322.cfgdata (field masks/values).

#ifndef TEST_PIC_PIC10F32X_CONFIG_H
#define TEST_PIC_PIC10F32X_CONFIG_H

#define PIC_CONFIG_WORD_ADDR   0x2007u   // program-memory WORD address
#define PIC_CONFIG_IMPL_MASK   0x1FFFu   // implemented bits
#define PIC_CONFIG_DEFAULT     0x3FFFu   // erased/default value (all 1s within 14-bit word)

// Per-field masks (bit positions) and the values for the settings we intend.
// (mask, intended-value) pairs -- value is the raw bit pattern within the mask.
#define FOSC_MASK   0x0001u
#define FOSC_INTOSC 0x0000u
#define FOSC_EC     0x0001u

#define BOREN_MASK  0x0006u
#define BOREN_ON    0x0006u
#define BOREN_NSLP  0x0004u
#define BOREN_SBOD  0x0002u
#define BOREN_OFF   0x0000u

#define WDTE_MASK   0x0018u
#define WDTE_ON     0x0018u
#define WDTE_NSLP   0x0010u
#define WDTE_SWDTEN 0x0008u
#define WDTE_OFF    0x0000u

#define PWRTE_MASK  0x0020u
#define PWRTE_OFF   0x0020u
#define PWRTE_ON    0x0000u

#define MCLRE_MASK  0x0040u
#define MCLRE_ON    0x0040u
#define MCLRE_OFF   0x0000u

#define CP_MASK     0x0080u
#define CP_OFF      0x0080u
#define CP_ON       0x0000u

#define LVP_MASK    0x0100u
#define LVP_ON      0x0100u
#define LVP_OFF     0x0000u

#define LPBOR_MASK  0x0200u
#define LPBOR_ON    0x0200u
#define LPBOR_OFF   0x0000u

#define BORV_MASK   0x0400u
#define BORV_LO     0x0400u
#define BORV_HI     0x0000u

#define WRT_MASK    0x1800u
#define WRT_OFF     0x1800u
#define WRT_BOOT    0x1000u
#define WRT_HALF    0x0800u
#define WRT_ALL     0x0000u

// The intended CONFIG word (implemented bits) is the OR of the design-intent
// field values. This mirrors the #pragma config block in the PIC shell:
//   FOSC=INTOSC BOREN=ON WDTE=ON PWRTE=ON MCLRE=OFF CP=OFF LVP=OFF LPBOR=OFF
//   BORV=HI WRT=OFF
#define PIC_CONFIG_EXPECTED_MASKED ( (uint16_t)( \
    FOSC_INTOSC | BOREN_ON | WDTE_ON | PWRTE_ON | MCLRE_OFF | CP_OFF | \
    LVP_OFF | LPBOR_OFF | BORV_HI | WRT_OFF ) )           // = 0x189E

static void pic_config_check_fields(uint16_t impl) {
    CHECK((impl & FOSC_MASK)  == FOSC_INTOSC,
          "FOSC must be INTOSC (internal HFINTOSC); got field 0x%04X", (unsigned)(impl & FOSC_MASK));
    CHECK((impl & BOREN_MASK) == BOREN_ON,
          "BOREN must be ON (brown-out reset enabled); got field 0x%04X", (unsigned)(impl & BOREN_MASK));
    CHECK((impl & WDTE_MASK)  == WDTE_ON,
          "WDTE must be ON (watchdog cannot be disabled by software); got field 0x%04X", (unsigned)(impl & WDTE_MASK));
    CHECK((impl & PWRTE_MASK) == PWRTE_ON,
          "PWRTE must be ON (power-up timer, let supply settle); got field 0x%04X", (unsigned)(impl & PWRTE_MASK));
    CHECK((impl & MCLRE_MASK) == MCLRE_OFF,
          "MCLRE must be OFF (RA3 is the digital footswitch input, not MCLR); got field 0x%04X", (unsigned)(impl & MCLRE_MASK));
    CHECK((impl & CP_MASK)    == CP_OFF,
          "CP must be OFF (no code protection); got field 0x%04X", (unsigned)(impl & CP_MASK));
    CHECK((impl & LVP_MASK)   == LVP_OFF,
          "LVP must be OFF (high-voltage programming; RA3/PGM not consumed); got field 0x%04X", (unsigned)(impl & LVP_MASK));
    CHECK((impl & LPBOR_MASK) == LPBOR_OFF,
          "LPBOR must be OFF (standard BOR via BOREN); got field 0x%04X", (unsigned)(impl & LPBOR_MASK));
    CHECK((impl & BORV_MASK)  == BORV_HI,
          "BORV must be HI (higher/earlier BOR trip point); got field 0x%04X", (unsigned)(impl & BORV_MASK));
    CHECK((impl & WRT_MASK)   == WRT_OFF,
          "WRT must be OFF (no flash self-write protection); got field 0x%04X", (unsigned)(impl & WRT_MASK));
}

// -------------------------------------------------------------------------
// CRITICAL CROSS-CHECKS: three bits whose mis-setting is invisible to every
// other test and breaks the device on real silicon. Re-asserted explicitly
// (same spirit as the AVR fuse test's BOD 4.3V cross-check) so the design
// INTENT, not just the bit pattern, is on record.
//   WDTE=ON  : the fault-recovery path (hw_force_wdt_reset) needs the WDT.
//   MCLRE=OFF: RA3 must be the footswitch input, not MCLR/VPP.
//   BOREN=ON : brown-out protection during relay/MOSFET actuation.
// -------------------------------------------------------------------------
static void pic_config_check_intent(uint16_t impl) {
    CHECK((impl & WDTE_MASK) == WDTE_ON,
          "DESIGN INTENT: the watchdog MUST be enabled (WDTE=ON) -- the firmware's "
          "fault recovery relies on a WDT reset; WDTE=OFF would hang forever.");
    CHECK((impl & MCLRE_MASK) == MCLRE_OFF,
          "DESIGN INTENT: MCLRE MUST be OFF so RA3 is a digital input (the "
          "footswitch); MCLRE=ON repurposes RA3 as MCLR and breaks the switch.");
    CHECK((impl & BOREN_MASK) == BOREN_ON,
          "DESIGN INTENT: brown-out reset MUST be enabled (BOREN=ON).");
}

#endif // TEST_PIC_PIC10F32X_CONFIG_H
