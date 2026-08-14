// PIC12F675 CONFIG-word decode table for test_config_pic_core.h.
//
// Same CONFIG address as the PIC10F32x (program-memory WORD 0x2007) and not one
// shared bit position beyond it. Absent relative to the 10F32x: LVP, WRT, BORV,
// LPBOR. New here: CPD (data/EEPROM code protection) and BG<1:0> (bandgap
// calibration), and FOSC widens from one bit to three.
//
// Masks and values are taken verbatim from the DFP cfgdata for this exact
// device -- `CWORD:2007:31FF:31FF:CONFIG` -- not from the datasheet prose and
// not from the 10F32x table.
//
// References:
//   PIC12F629/675 datasheet DS41190, "Configuration Word".
//   DFP cfgdata: <DFP>/xc8/pic/dat/cfgdata/12f675.cfgdata (field masks/values).

#ifndef TEST_PIC_PIC12F675_CONFIG_H
#define TEST_PIC_PIC12F675_CONFIG_H

#define PIC_CONFIG_WORD_ADDR   0x2007u   // program-memory WORD address
#define PIC_CONFIG_IMPL_MASK   0x31FFu   // implemented bits: 0x01FF settable + 0x3000 calibration
#define PIC_CONFIG_DEFAULT     0x31FFu   // erased value; note bits 0x0E00 are NOT implemented here,
                                         // so unlike the 10F32x they read back as 0, not 1

// FOSC is three bits and picks which of GP4/GP5 stay usable as I/O. THIS IS NOT
// A COSMETIC FIELD ON THIS PART: GP5 carries the footswitch, and six of the
// eight settings hand GP5 to an oscillator or clock input. INTRCIO -- internal
// oscillator, I/O function on BOTH GP4 and GP5 -- is the only internal-clock
// setting that leaves the footswitch pin alone.
#define FOSC_MASK      0x0007u
#define FOSC_LP        0x0000u
#define FOSC_XT        0x0001u
#define FOSC_HS        0x0002u
#define FOSC_EC        0x0003u
#define FOSC_INTRCIO   0x0004u   // INTOSC, I/O on GP4 and GP5   <- the only one this design can use
#define FOSC_INTRCCLK  0x0005u   // INTOSC, CLKOUT on GP4
#define FOSC_EXTRCIO   0x0006u
#define FOSC_EXTRCCLK  0x0007u

#define WDTE_MASK   0x0008u
#define WDTE_ON     0x0008u
#define WDTE_OFF    0x0000u

#define PWRTE_MASK  0x0010u
#define PWRTE_OFF   0x0010u
#define PWRTE_ON    0x0000u

#define MCLRE_MASK  0x0020u
#define MCLRE_ON    0x0020u
#define MCLRE_OFF   0x0000u

#define BOREN_MASK  0x0040u
#define BOREN_ON    0x0040u
#define BOREN_OFF   0x0000u

#define CP_MASK     0x0080u
#define CP_OFF      0x0080u
#define CP_ON       0x0000u

#define CPD_MASK    0x0100u
#define CPD_OFF     0x0100u
#define CPD_ON      0x0000u

// BG<1:0> is FACTORY BANDGAP CALIBRATION, not a setting. The cfgdata implements
// the bits but declares no CSETTING for them, because nothing in a #pragma
// config block is supposed to write them: like the OSCCAL word at 0x3FF, they
// are trim the programmer must preserve across an erase. This table proves only
// the build-side half: the image leaves them ERASED (0b11), so the toolchain is
// not quietly programming a calibration value of its own over every device.
// Whether a real programmer preserves the device value is hardware-unvalidated.
#define BG_MASK     0x3000u
#define BG_ERASED   0x3000u

// The intended CONFIG word (implemented bits) is the OR of the design-intent
// field values plus the erased calibration bits. This mirrors the #pragma config
// block in the PIC12F675 shell:
//   FOSC=INTRCIO WDTE=ON PWRTE=ON MCLRE=OFF BOREN=ON CP=OFF CPD=OFF
#define PIC_CONFIG_EXPECTED_MASKED ( (uint16_t)( \
    FOSC_INTRCIO | WDTE_ON | PWRTE_ON | MCLRE_OFF | BOREN_ON | CP_OFF | \
    CPD_OFF | BG_ERASED ) )                               // = 0x31CC

static void pic_config_check_fields(uint16_t impl) {
    CHECK((impl & FOSC_MASK)  == FOSC_INTRCIO,
          "FOSC must be INTRCIO (INTOSC with I/O on GP4 and GP5); got field 0x%04X", (unsigned)(impl & FOSC_MASK));
    CHECK((impl & BOREN_MASK) == BOREN_ON,
          "BOREN must be ON (brown-out detect enabled); got field 0x%04X", (unsigned)(impl & BOREN_MASK));
    CHECK((impl & WDTE_MASK)  == WDTE_ON,
          "WDTE must be ON (watchdog cannot be disabled by software); got field 0x%04X", (unsigned)(impl & WDTE_MASK));
    CHECK((impl & PWRTE_MASK) == PWRTE_ON,
          "PWRTE must be ON (power-up timer, let supply settle); got field 0x%04X", (unsigned)(impl & PWRTE_MASK));
    CHECK((impl & MCLRE_MASK) == MCLRE_OFF,
          "MCLRE must be OFF (GP3 stays a digital input, MCLR tied internally to VDD); got field 0x%04X", (unsigned)(impl & MCLRE_MASK));
    CHECK((impl & CP_MASK)    == CP_OFF,
          "CP must be OFF (no program-memory code protection); got field 0x%04X", (unsigned)(impl & CP_MASK));
    CHECK((impl & CPD_MASK)   == CPD_OFF,
          "CPD must be OFF (no data-memory code protection); got field 0x%04X", (unsigned)(impl & CPD_MASK));
    CHECK((impl & BG_MASK)    == BG_ERASED,
          "BG must be left ERASED (0x3000): the bandgap bits are factory calibration "
          "outside the image; a build that writes them replaces that trim on every "
          "device, while programmer preservation requires hardware evidence; got field 0x%04X", (unsigned)(impl & BG_MASK));
}

// -------------------------------------------------------------------------
// CRITICAL CROSS-CHECKS: bits whose mis-setting is invisible to every other
// test and breaks the device on real silicon. Re-asserted explicitly (same
// spirit as the AVR fuse test's BOD 4.3V cross-check) so the design INTENT,
// not just the bit pattern, is on record.
//
// The set is NOT the PIC10F32x's set with the names changed:
//   WDTE=ON     : same reason -- hw_force_wdt_reset() needs the WDT.
//   FOSC=INTRCIO: NEW. On the 10F32x, FOSC is one bit and the footswitch pin is
//                 never at stake. Here seven of eight settings hand GP4 and/or
//                 GP5 to an oscillator: six claim footswitch GP5, and the other
//                 claims parked-output GP4. Only INTRCIO preserves both roles.
//   MCLRE=OFF   : same bit, DIFFERENT reason. On the 10F32x, MCLRE=ON steals RA3,
//                 which is that part's footswitch. Here the footswitch is GP5 and
//                 MCLRE governs GP3. The reference board gives GP3 an ICSP-safe
//                 external pull-up, but its declared role is a digital spare input;
//                 MCLRE=ON would silently turn it into the reset input instead.
//   BOREN=ON    : same reason -- brown-out protection during actuation.
// -------------------------------------------------------------------------
static void pic_config_check_intent(uint16_t impl) {
    CHECK((impl & WDTE_MASK) == WDTE_ON,
          "DESIGN INTENT: the watchdog MUST be enabled (WDTE=ON) -- the firmware's "
          "fault recovery relies on a WDT reset; WDTE=OFF would hang forever.");
    CHECK((impl & FOSC_MASK) == FOSC_INTRCIO,
          "DESIGN INTENT: FOSC MUST be INTRCIO so GP5 and GP4 remain digital I/O -- "
          "GP5 carries the footswitch and GP4 is the guarded low-driven spare.");
    CHECK((impl & MCLRE_MASK) == MCLRE_OFF,
          "DESIGN INTENT: MCLRE MUST be OFF so GP3 remains the externally pulled-up "
          "digital spare input rather than becoming an external reset input.");
    CHECK((impl & BOREN_MASK) == BOREN_ON,
          "DESIGN INTENT: brown-out reset MUST be enabled (BOREN=ON).");
}

#endif // TEST_PIC_PIC12F675_CONFIG_H
