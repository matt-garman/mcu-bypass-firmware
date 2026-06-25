// Host-compiled PIC10F322 CONFIG-word decoder / verifier.
//
// WHY THIS EXISTS
// ---------------
// The firmware's correctness depends on the device CONFIG word, which is set in
// the C source via `#pragma config` (see src/bypass_mcu_pic10f32x.c). A wrong
// CONFIG bit does NOT show up in any host/formal test (those compile only the
// MCU-neutral pure core) and the PIC shell has no simavr lock-step harness -- a
// fat-fingered pragma would only bite on real silicon:
//   - WDTE=OFF  -> the fault watchdog never fires; hw_force_wdt_reset() hangs
//                  forever instead of recovering (the whole fault-recovery story
//                  is load-bearing).
//   - MCLRE=ON  -> RA3 becomes MCLR/VPP, NOT a digital input; the footswitch
//                  (wired to RA3) stops working entirely.
//   - BOREN=OFF -> no brown-out reset; supply sag can leave the MCU in an
//                  undefined state with the relay/MOSFET mid-actuation.
//   - FOSC!=INTOSC / wrong osc -> wrong tick + wrong relay/mute pulse widths.
//
// This is the PIC analogue of test/avr/test_fuses.c, but STRONGER: rather than
// re-checking a value the Makefile injects, it parses the EXACT CONFIG word the
// XC8 compiler emitted into the built Intel-HEX from those `#pragma config`
// lines, and asserts it matches the documented design intent. So a bad pragma
// edit (in firmware the test suite otherwise cannot see) fails here instead of
// on a bench session.
//
// USAGE
//   test_config_pic <file.hex> [<file.hex> ...]
// The Makefile's `pic-test-config` target builds the HEX (via `make pic`) and
// runs this against every build_pic/*.hex. All three output variants share the
// same shell + the same #pragma config, so every variant's CONFIG word must be
// identical; checking them all also catches any accidental divergence.
//
// References:
//   PIC10(L)F320/322 datasheet DS40001585, "Configuration Word".
//   DFP cfgdata: <DFP>/xc8/pic/dat/cfgdata/10f322.cfgdata (field masks/values).

#include <stdint.h>
#include <stdio.h>
#include <string.h>

//////////////////////////////////////////////////////////////////////////////
// CONFIG word location + field map (PIC10F322)
//
// The CONFIG word lives at PROGRAM-MEMORY WORD address 0x2007. Intel HEX uses
// BYTE addresses, and PIC program words are stored little-endian (low byte
// first), so the word occupies BYTE addresses 0x400E (low) and 0x400F (high):
//     byte_addr = word_addr * 2  =>  0x2007 * 2 = 0x400E
//
// Implemented bits are 0x1FFF (bits 0..12); the unimplemented upper bits read
// as 1, so the device default is 0x3FFF and the only "extra" set bit in a built
// image is bit 13 (0x2000). Field masks/values are taken verbatim from the DFP
// cfgdata for this exact device.
//////////////////////////////////////////////////////////////////////////////

#define CONFIG_WORD_ADDR   0x2007u            // program-memory WORD address
#define CONFIG_BYTE_ADDR   (CONFIG_WORD_ADDR * 2u) // = 0x400E (Intel-HEX byte address)

#define CONFIG_IMPL_MASK   0x1FFFu            // implemented bits
#define CONFIG_DEFAULT     0x3FFFu            // erased/default value (all 1s within 14-bit word)
// Bits that are unimplemented but still appear set (read as 1) in a built image.
#define CONFIG_UNIMPL_BITS ((uint16_t)(CONFIG_DEFAULT & ~CONFIG_IMPL_MASK)) // = 0x2000

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
#define EXPECTED_MASKED ( (uint16_t)( \
    FOSC_INTOSC | BOREN_ON | WDTE_ON | PWRTE_ON | MCLRE_OFF | CP_OFF | \
    LVP_OFF | LPBOR_OFF | BORV_HI | WRT_OFF ) )           // = 0x189E
// The full word as it appears in a built image (implemented intent + the
// unimplemented bits that read 1).
#define EXPECTED_FULL   ((uint16_t)(EXPECTED_MASKED | CONFIG_UNIMPL_BITS)) // = 0x389E

//////////////////////////////////////////////////////////////////////////////
// Tiny check harness (same shape as test/avr/test_fuses.c)
//////////////////////////////////////////////////////////////////////////////

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

//////////////////////////////////////////////////////////////////////////////
// Minimal Intel-HEX reader -- just enough to fetch the two CONFIG bytes.
//
// Record layout:  :LL AAAA TT [DD..] CC
//   LL = data byte count, AAAA = 16-bit address, TT = record type,
//   CC = two's-complement checksum of all preceding bytes.
// Types handled: 00 (data), 01 (EOF), 02 (ext segment addr), 04 (ext linear
// addr). The upper-address records keep this robust even though a PIC10F322
// image never exceeds the 16-bit space.
//////////////////////////////////////////////////////////////////////////////

static int hexval(int c) {
    if (c >= '0' && c <= '9') { return c - '0'; }
    if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
    if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
    return -1;
}

// Read two hex chars from s[*i], advance *i by 2; return 0..255 or -1 on error.
static int read_byte(const char *s, size_t len, size_t *i) {
    if (*i + 2u > len) { return -1; }
    int hi = hexval((unsigned char)s[*i]);
    int lo = hexval((unsigned char)s[*i + 1u]);
    if (hi < 0 || lo < 0) { return -1; }
    *i += 2u;
    return (hi << 4) | lo;
}

// Parse the HEX file; on success store the CONFIG bytes (low,high) into out_lo/
// out_hi and return 1. Returns 0 if the file can't be read/parsed; returns -1 if
// parsed cleanly but no data covered the CONFIG address.
static int read_config_word(const char *path, uint8_t *out_lo, uint8_t *out_hi) {
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "FAIL: cannot open HEX file '%s'\n", path);
        return 0;
    }

    uint32_t ext_base = 0;       // upper address bits from type-02/04 records
    int found_lo = 0, found_hi = 0;
    uint8_t lo = 0xFF, hi = 0xFF;
    char line[600];
    int ok = 1;

    while (fgets(line, (int)sizeof(line), f) != NULL) {
        // strip trailing CR/LF
        size_t len = strlen(line);
        while (len > 0u && (line[len - 1u] == '\n' || line[len - 1u] == '\r')) { len--; }
        if (len == 0u) { continue; }
        if (line[0] != ':') { continue; } // not a record line

        size_t i = 1u;
        int cnt  = read_byte(line, len, &i);
        int a_hi = read_byte(line, len, &i);
        int a_lo = read_byte(line, len, &i);
        int type = read_byte(line, len, &i);
        if (cnt < 0 || a_hi < 0 || a_lo < 0 || type < 0) {
            fprintf(stderr, "FAIL: malformed HEX record in '%s'\n", path);
            ok = 0; break;
        }
        uint32_t rec_addr = ((uint32_t)a_hi << 8) | (uint32_t)a_lo;

        // read the data bytes (we need their values for type 00/02/04)
        int data[256];
        for (int d = 0; d < cnt; d++) {
            int b = read_byte(line, len, &i);
            if (b < 0) { fprintf(stderr, "FAIL: truncated HEX data in '%s'\n", path); ok = 0; break; }
            data[d] = b;
        }
        if (!ok) { break; }

        if (type == 0x01) {            // EOF
            break;
        } else if (type == 0x04) {     // extended linear address (upper 16 bits)
            if (cnt == 2) { ext_base = (((uint32_t)data[0] << 8) | (uint32_t)data[1]) << 16; }
            continue;
        } else if (type == 0x02) {     // extended segment address (upper bits, x16)
            if (cnt == 2) { ext_base = (((uint32_t)data[0] << 8) | (uint32_t)data[1]) << 4; }
            continue;
        } else if (type != 0x00) {     // ignore any other record type
            continue;
        }

        // data record: see whether it covers either CONFIG byte address
        for (int d = 0; d < cnt; d++) {
            uint32_t abs_addr = ext_base + rec_addr + (uint32_t)d;
            if (abs_addr == CONFIG_BYTE_ADDR)        { lo = (uint8_t)data[d]; found_lo = 1; }
            else if (abs_addr == CONFIG_BYTE_ADDR + 1u) { hi = (uint8_t)data[d]; found_hi = 1; }
        }
    }
    fclose(f);

    if (!ok) { return 0; }
    if (!found_lo || !found_hi) {
        fprintf(stderr, "FAIL: '%s' contains no data at CONFIG address 0x%04X\n",
                path, (unsigned)CONFIG_BYTE_ADDR);
        return -1;
    }
    *out_lo = lo;
    *out_hi = hi;
    return 1;
}

//////////////////////////////////////////////////////////////////////////////
// Field decode + design-intent verification
//////////////////////////////////////////////////////////////////////////////

static void verify_config(const char *path, uint16_t word) {
    uint16_t impl = (uint16_t)(word & CONFIG_IMPL_MASK);

    printf("  %s: CONFIG=0x%04X (implemented bits 0x%04X)\n", path, word, impl);

    // --- field-by-field against the documented design intent ---
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

    // --- whole-word cross-checks ---
    CHECK(impl == EXPECTED_MASKED,
          "implemented CONFIG bits must equal 0x%04X (design intent); got 0x%04X",
          (unsigned)EXPECTED_MASKED, (unsigned)impl);
    CHECK(word == EXPECTED_FULL,
          "built CONFIG word must equal 0x%04X (intent | unimplemented-read-1 bits); got 0x%04X",
          (unsigned)EXPECTED_FULL, (unsigned)word);

    // -------------------------------------------------------------------------
    // CRITICAL CROSS-CHECKS: three bits whose mis-setting is invisible to every
    // other test and breaks the device on real silicon. Re-asserted explicitly
    // (same spirit as the AVR fuse test's BOD 4.3V cross-check) so the design
    // INTENT, not just the bit pattern, is on record.
    //   WDTE=ON  : the fault-recovery path (hw_force_wdt_reset) needs the WDT.
    //   MCLRE=OFF: RA3 must be the footswitch input, not MCLR/VPP.
    //   BOREN=ON : brown-out protection during relay/MOSFET actuation.
    // -------------------------------------------------------------------------
    CHECK((impl & WDTE_MASK) == WDTE_ON,
          "DESIGN INTENT: the watchdog MUST be enabled (WDTE=ON) -- the firmware's "
          "fault recovery relies on a WDT reset; WDTE=OFF would hang forever.");
    CHECK((impl & MCLRE_MASK) == MCLRE_OFF,
          "DESIGN INTENT: MCLRE MUST be OFF so RA3 is a digital input (the "
          "footswitch); MCLRE=ON repurposes RA3 as MCLR and breaks the switch.");
    CHECK((impl & BOREN_MASK) == BOREN_ON,
          "DESIGN INTENT: brown-out reset MUST be enabled (BOREN=ON).");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file.hex> [<file.hex> ...]\n", argv[0]);
        return 2;
    }

    printf("PIC10F322 CONFIG-word verification (word addr 0x%04X / byte 0x%04X):\n",
           (unsigned)CONFIG_WORD_ADDR, (unsigned)CONFIG_BYTE_ADDR);

    for (int a = 1; a < argc; a++) {
        uint8_t lo = 0, hi = 0;
        int r = read_config_word(argv[a], &lo, &hi);
        if (r != 1) {
            g_failures++;   // read_config_word already printed the reason
            continue;
        }
        uint16_t word = (uint16_t)((uint16_t)lo | ((uint16_t)hi << 8));
        verify_config(argv[a], word);
    }

    printf("CONFIG checks: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
