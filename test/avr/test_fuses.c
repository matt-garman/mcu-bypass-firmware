// Host-compiled fuse-byte decoder / verifier.
//
// WHY THIS EXISTS
// ---------------
// The firmware's correctness depends on fuse bytes that are configured OUTSIDE
// the C source (in the Makefile, written by avrdude). A wrong fuse byte does
// not show up in any simavr or golden-model test -- it only bites on real
// silicon (wrong clock => wrong debounce timing; BOD off => brown-out glitches;
// RSTDISBL set => bricked ISP). This test decodes the EXACT fuse bytes the
// Makefile will burn and asserts they match the documented design intent, so a
// fat-fingered fuse edit fails CI instead of a bench session.
//
// The fuse byte values are injected by the Makefile via -D so there is a single
// source of truth (the Makefile's classic-AVR and XT_FUSE_* variables):
//   -DT13_LFUSE=... -DT13_HFUSE=... -DT85_LFUSE=... -DT85_HFUSE=...
//   -DT202_WDTCFG=... -DT202_BODCFG=... -DT202_OSCCFG=...
//   -DT202_SYSCFG0=... -DT202_SYSCFG1=... -DT202_APPEND=...
//   -DT202_BOOTEND=...
//
// Datasheet references:
//   ATtiny13A  rev. 8126F, "Fuse Bytes" (low/high byte bit maps)
//   ATtiny25/45/85 rev. 2586Q, "Fuse Bytes"
//   ATtiny202/204/402/404/406 family data sheet, "FUSE - Fuses"
//
// Classic AVR fuses are active-low. AVR-XT fuses use encoded byte fields.

#include <stdint.h>
#include <stdio.h>

#ifndef T13_LFUSE
#  define T13_LFUSE 0x6a
#endif
#ifndef T13_HFUSE
#  define T13_HFUSE 0xf9
#endif
#ifndef T85_LFUSE
#  define T85_LFUSE 0x62
#endif
#ifndef T85_HFUSE
#  define T85_HFUSE 0xcc
#endif
#ifndef T202_WDTCFG
#  define T202_WDTCFG 0x06
#endif
#ifndef T202_BODCFG
#  define T202_BODCFG 0xe5
#endif
#ifndef T202_OSCCFG
#  define T202_OSCCFG 0x01
#endif
#ifndef T202_SYSCFG0
#  define T202_SYSCFG0 0xf6
#endif
#ifndef T202_SYSCFG1
#  define T202_SYSCFG1 0x07
#endif
#ifndef T202_APPEND
#  define T202_APPEND 0x00
#endif
#ifndef T202_BOOTEND
#  define T202_BOOTEND 0x00
#endif

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, ...) do {                                  \
    g_checks++;                                                \
    if (!(cond)) {                                             \
        g_failures++;                                          \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);   \
        fprintf(stderr, __VA_ARGS__);                          \
        fprintf(stderr, "\n");                                 \
    }                                                          \
} while (0)

// Extract a contiguous bit field [lsb .. lsb+width-1] from a byte.
static unsigned field(unsigned byte, unsigned lsb, unsigned width) {
    return (byte >> lsb) & ((1u << width) - 1u);
}

static void verify_byte_range(const char *name, unsigned value) {
    CHECK(value <= 0xffu, "%s must fit in one fuse byte; got 0x%x", name, value);
}

//////////////////////////////////////////////////////////////////////////////
// ATtiny13A fuse map (datasheet 8126F; cross-checked against avr-libc
// iotn13a.h FUSE_* macros).
//
// LOW byte:
//   bit7 SPIEN      (0=enabled)      -- ISP programming
//   bit6 EESAVE     (0=preserve EEPROM on chip erase)
//   bit5 WDTON      (0=WDT always on)
//   bit4 CKDIV8     (0=enabled -> /8)
//   bit3 SUT1
//   bit2 SUT0
//   bit1 CKSEL1
//   bit0 CKSEL0
//   (CKSEL[1:0]=10 -> 9.6 MHz internal RC; SUT[1:0]=10 -> 14CK + 64ms)
//
// HIGH byte (NOTE: layout differs from the ATtiny85!):
//   bit7..bit5 = 1 (reserved, read 1)
//   bit4 SELFPRGEN (1=disabled)
//   bit3 DWEN      (1=disabled -> PB5 stays RESET/ISP)
//   bit2 BODLEVEL1
//   bit1 BODLEVEL0
//   bit0 RSTDISBL  (1=external RESET enabled -> PB5 stays RESET/ISP)
//   BODLEVEL[1:0] (bit2,bit1): 11=BOD off, 10=1.8V, 01=2.7V, 00=4.3V
//////////////////////////////////////////////////////////////////////////////
static void verify_t13(void) {
    unsigned lo = (unsigned)T13_LFUSE;
    unsigned hi = (unsigned)T13_HFUSE;

    printf("  ATtiny13a: lfuse=0x%02x hfuse=0x%02x\n", lo, hi);

    // --- LOW byte ---
    CHECK(field(lo, 7, 1) == 0, "t13 SPIEN must be enabled (0) to keep ISP; lfuse bit7=%u", field(lo,7,1));
    CHECK(field(lo, 5, 1) == 0, "t13 WDTON must be 0 (WDT forced always-on, cannot be disabled by software); lfuse bit5=%u", field(lo,5,1));
    CHECK(field(lo, 4, 1) == 0, "t13 CKDIV8 must be enabled (0) for 1.2MHz; lfuse bit4=%u", field(lo,4,1));
    CHECK(field(lo, 0, 2) == 0x2, "t13 CKSEL[1:0] must be 0b10 (9.6MHz int RC); got 0b%u%u",
          field(lo,1,1), field(lo,0,1));
    CHECK(field(lo, 2, 2) == 0x2, "t13 SUT[1:0] must be 0b10 (14CK+64ms, stable LDO ramp); got 0b%u%u",
          field(lo,3,1), field(lo,2,1));

    // --- HIGH byte ---
    CHECK(field(hi, 5, 3) == 0x7, "t13 hfuse bits 7:5 reserved, should read 1; got 0x%x", field(hi,5,3));
    CHECK(field(hi, 4, 1) == 1, "t13 SELFPRGEN must be disabled (1); hfuse bit4=%u", field(hi,4,1));
    CHECK(field(hi, 3, 1) == 1, "t13 DWEN must be disabled (1) so PB5 stays RESET/ISP; hfuse bit3=%u", field(hi,3,1));
    CHECK(field(hi, 0, 1) == 1, "t13 RSTDISBL must be 1 (external RESET kept, ISP preserved); hfuse bit0=%u", field(hi,0,1));
    // BODLEVEL[1:0] = (bit2,bit1). 0b00 == 4.3V on the ATtiny13A.
    CHECK(field(hi, 1, 2) == 0x0, "t13 BODLEVEL[1:0] must be 0b00 (4.3V); got 0b%u%u",
          field(hi,2,1), field(hi,1,1));
}

//////////////////////////////////////////////////////////////////////////////
// ATtiny85 fuse map (2586Q)
//
// LOW byte:
//   bit7 CKDIV8 (0=enabled -> /8)
//   bit6 CKOUT  (1=disabled)
//   bit5 SUT1
//   bit4 SUT0
//   bit3..bit0 CKSEL[3:0]  (0010 -> 8 MHz internal RC)
//   (SUT[1:0]=10 -> 14CK + 64ms with the int-RC range)
//
// HIGH byte:
//   bit7 RSTDISBL  (1=disabled -> PB5 stays RESET)
//   bit6 DWEN      (1=disabled)
//   bit5 SPIEN     (0=enabled)
//   bit4 WDTON     (1=WDT not forced on)
//   bit3 EESAVE    (1=don't preserve EEPROM)
//   bit2 BODLEVEL2
//   bit1 BODLEVEL1
//   bit0 BODLEVEL0
//   (BODLEVEL[2:0]=101 -> 2.7V)
//////////////////////////////////////////////////////////////////////////////
static void verify_t85(void) {
    unsigned lo = (unsigned)T85_LFUSE;
    unsigned hi = (unsigned)T85_HFUSE;

    printf("  ATtiny85:  lfuse=0x%02x hfuse=0x%02x\n", lo, hi);

    // --- LOW byte ---
    CHECK(field(lo, 7, 1) == 0, "t85 CKDIV8 must be enabled (0) for 1.0MHz; lfuse bit7=%u", field(lo,7,1));
    CHECK(field(lo, 6, 1) == 1, "t85 CKOUT should be disabled (1); lfuse bit6=%u", field(lo,6,1));
    CHECK(field(lo, 0, 4) == 0x2, "t85 CKSEL[3:0] must be 0b0010 (8MHz int RC); got 0x%x", field(lo,0,4));
    CHECK(field(lo, 4, 2) == 0x2, "t85 SUT[1:0] must be 0b10 (14CK+64ms); got 0b%u%u",
          field(lo,5,1), field(lo,4,1));

    // --- HIGH byte ---
    CHECK(field(hi, 7, 1) == 1, "t85 RSTDISBL must be 1 (PB5 stays RESET, keep ISP); hfuse bit7=%u", field(hi,7,1));
    CHECK(field(hi, 6, 1) == 1, "t85 DWEN must be disabled (1); hfuse bit6=%u", field(hi,6,1));
    CHECK(field(hi, 5, 1) == 0, "t85 SPIEN must be enabled (0) to keep ISP; hfuse bit5=%u", field(hi,5,1));
    CHECK(field(hi, 4, 1) == 0, "t85 WDTON must be 0 (WDT forced always-on, cannot be disabled by software); hfuse bit4=%u", field(hi,4,1));
    CHECK(field(hi, 0, 3) == 0x4, "t85 BODLEVEL[2:0] must be 0b100 (4.3V); got 0x%x", field(hi,0,3));
}

//////////////////////////////////////////////////////////////////////////////
// ATtiny202 fuse map (AVR-XT encoded fields; bytes are written as named fuse
// memories by attiny202-fuses).
//
// WDTCFG:  WINDOW[7:4]=0 (off), PERIOD[3:0]=6 (256 cycles, fuse-locked).
// BODCFG:  LVL[7:5]=7 (~4.2V), SAMPFREQ[4]=0,
//          ACTIVE[3:2]=1 (enabled), SLEEP[1:0]=1 (enabled).
// OSCCFG:  FREQSEL[1:0]=1 (16 MHz).
// SYSCFG0: CRCSRC[7:6]=3 (no CRC), RSTPINCFG[3:2]=1 (UPDI).
// SYSCFG1: SUT[2:0]=7 (64 ms startup delay).
// APPEND/BOOTEND: both zero (one application section, no boot section).
//////////////////////////////////////////////////////////////////////////////
static void verify_t202(void) {
    unsigned wdtcfg = (unsigned)T202_WDTCFG;
    unsigned bodcfg = (unsigned)T202_BODCFG;
    unsigned osccfg = (unsigned)T202_OSCCFG;
    unsigned syscfg0 = (unsigned)T202_SYSCFG0;
    unsigned syscfg1 = (unsigned)T202_SYSCFG1;
    unsigned append = (unsigned)T202_APPEND;
    unsigned bootend = (unsigned)T202_BOOTEND;

    printf("  ATtiny202:  WDTCFG=0x%02x BODCFG=0x%02x OSCCFG=0x%02x "
           "SYSCFG0=0x%02x SYSCFG1=0x%02x APPEND=0x%02x BOOTEND=0x%02x\n",
           wdtcfg, bodcfg, osccfg, syscfg0, syscfg1, append, bootend);

    verify_byte_range("t202 WDTCFG", wdtcfg);
    verify_byte_range("t202 BODCFG", bodcfg);
    verify_byte_range("t202 OSCCFG", osccfg);
    verify_byte_range("t202 SYSCFG0", syscfg0);
    verify_byte_range("t202 SYSCFG1", syscfg1);
    verify_byte_range("t202 APPEND", append);
    verify_byte_range("t202 BOOTEND", bootend);

    // Exact-byte checks catch unexpected reserved-bit changes as well as fields.
    CHECK(wdtcfg == 0x06u, "t202 WDTCFG must be 0x06; got 0x%02x", wdtcfg);
    CHECK(bodcfg == 0xe5u, "t202 BODCFG must be 0xe5; got 0x%02x", bodcfg);
    CHECK(osccfg == 0x01u, "t202 OSCCFG must be 0x01; got 0x%02x", osccfg);
    CHECK(syscfg0 == 0xf6u, "t202 SYSCFG0 must be 0xf6; got 0x%02x", syscfg0);
    CHECK(syscfg1 == 0x07u, "t202 SYSCFG1 must be 0x07; got 0x%02x", syscfg1);
    CHECK(append == 0x00u, "t202 APPEND must be 0x00; got 0x%02x", append);
    CHECK(bootend == 0x00u, "t202 BOOTEND must be 0x00; got 0x%02x", bootend);

    CHECK(field(wdtcfg, 4, 4) == 0x0u,
          "t202 WDTCFG.WINDOW must be OFF (0); got 0x%x", field(wdtcfg,4,4));
    CHECK(field(wdtcfg, 0, 4) == 0x6u,
          "t202 WDTCFG.PERIOD must be 256 cycles (6); got 0x%x", field(wdtcfg,0,4));
    CHECK(field(bodcfg, 5, 3) == 0x7u,
          "t202 BODCFG.LVL must be BODLEVEL7 (~4.2V); got %u", field(bodcfg,5,3));
    CHECK(field(bodcfg, 4, 1) == 0x0u,
          "t202 BODCFG.SAMPFREQ must be 0; got %u", field(bodcfg,4,1));
    CHECK(field(bodcfg, 2, 2) == 0x1u,
          "t202 BODCFG.ACTIVE must be ENABLED (1); got %u", field(bodcfg,2,2));
    CHECK(field(bodcfg, 0, 2) == 0x1u,
          "t202 BODCFG.SLEEP must be ENABLED (1); got %u", field(bodcfg,0,2));
    CHECK(field(osccfg, 0, 2) == 0x1u,
          "t202 OSCCFG.FREQSEL must be 16 MHz (1); got %u", field(osccfg,0,2));
    CHECK(field(syscfg0, 6, 2) == 0x3u,
          "t202 SYSCFG0.CRCSRC must be no CRC (3); got %u", field(syscfg0,6,2));
    CHECK(field(syscfg0, 2, 2) == 0x1u,
          "t202 SYSCFG0.RSTPINCFG must preserve UPDI (1); got %u", field(syscfg0,2,2));
    CHECK(field(syscfg1, 0, 3) == 0x7u,
          "t202 SYSCFG1.SUT must be 64 ms (7); got %u", field(syscfg1,0,3));
}

int main(void) {
    printf("fuse-byte verification:\n");
    verify_t13();
    verify_t85();
    verify_t202();

    // -------------------------------------------------------------------------
    // CRITICAL CROSS-CHECK: the design spec (the design doc / bypass_mcu_avr_classic.c header)
    // states "enable brown-out detection (BOD) near the peripheral-safe 4.3V
    // floor". Verify every part actually encodes that intent, since a wrong
    // BODLEVEL is invisible to every
    // other test (it only bites as brown-out glitches on real silicon).
    //
    //   ATtiny13a: hfuse BODLEVEL[1:0] = (bit2,bit1); 0b00 == 4.3V.
    //   ATtiny85:  hfuse BODLEVEL[2:0] = (bit2,bit1,bit0); 0b100 == 4.3V.
    //   ATtiny202: BODCFG LVL[2:0] = bits[7:5]; 0b111 == BODLEVEL7 (~4.2V).
    // -------------------------------------------------------------------------
    {
        unsigned t13_bodlevel = field((unsigned)T13_HFUSE, 1, 2);
        CHECK(t13_bodlevel == 0x0,
              "DESIGN INTENT: ATtiny13a BOD must be 4.3V (BODLEVEL=0b00). "
              "Configured hfuse=0x%02x has BODLEVEL=0b%u%u",
              (unsigned)T13_HFUSE, field((unsigned)T13_HFUSE,2,1), field((unsigned)T13_HFUSE,1,1));

        unsigned t85_bodlevel = field((unsigned)T85_HFUSE, 0, 3);
        CHECK(t85_bodlevel == 0x4,
              "DESIGN INTENT: ATtiny85 BOD must be 4.3V (BODLEVEL=0b100). "
              "Configured hfuse=0x%02x has BODLEVEL=0x%x",
              (unsigned)T85_HFUSE, t85_bodlevel);

        unsigned t202_bodlevel = field((unsigned)T202_BODCFG, 5, 3);
        CHECK(t202_bodlevel == 0x7,
              "DESIGN INTENT: ATtiny202 BOD must be BODLEVEL7 (~4.2V). "
              "Configured BODCFG=0x%02x has LVL=0x%x",
              (unsigned)T202_BODCFG, t202_bodlevel);
    }

    printf("fuse checks: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
