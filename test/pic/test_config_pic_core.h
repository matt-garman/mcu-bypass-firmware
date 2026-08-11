// Host-compiled PIC CONFIG-word decoder / verifier -- shared mechanism.
//
// WHY THIS EXISTS
// ---------------
// The firmware's correctness depends on the device CONFIG word, which is set in
// the C source via `#pragma config` (see the per-part shell in src/). A wrong
// CONFIG bit does NOT show up in any host/formal test (those compile only the
// MCU-neutral pure core) and the PIC shells have no simavr lock-step harness --
// a fat-fingered pragma would only bite on real silicon. Three settings are
// load-bearing on every PIC part this repository supports:
//   - WDTE=OFF  -> the fault watchdog never fires; hw_force_wdt_reset() hangs
//                  forever instead of recovering (the whole fault-recovery story
//                  is load-bearing).
//   - MCLRE=ON  -> the footswitch pin becomes MCLR/VPP, NOT a digital input; the
//                  footswitch stops working entirely.
//   - BOREN=OFF -> no brown-out reset; supply sag can leave the MCU in an
//                  undefined state with the relay/MOSFET mid-actuation.
// A wrong oscillator selection gives the wrong tick and wrong relay/mute pulse
// widths. Which bits carry those settings is a per-part fact; that they must be
// checked is not, which is the line this file draws.
//
// This is the PIC analogue of test/avr/test_fuses.c, but STRONGER: rather than
// re-checking a value the Makefile injects, it parses the EXACT CONFIG word the
// XC8 compiler emitted into the built Intel-HEX from those `#pragma config`
// lines, and asserts it matches the documented design intent. So a bad pragma
// edit (in firmware the test suite otherwise cannot see) fails here instead of
// on a bench session.
//
// WHAT IS DEVICE-NEUTRAL AND WHAT IS NOT
// --------------------------------------
// Everything below is mechanism: locate the CONFIG word in an Intel HEX at the
// part's word address, mask it, compare it against a documented intent, report.
// The decode TABLE -- field masks, the values that spell the intended settings,
// and the field-by-field assertions -- is a per-part fact and lives in the
// device header the adapter names. The PIC10F32x and PIC12F675 tables share not
// one bit position beyond the CONFIG address itself, so folding them into one
// table would produce a table true of neither part.
//
// USAGE
//   <adapter> <file.hex> [<file.hex> ...]
// The Makefile's `<part>-test-config` target builds the HEX and runs the adapter
// against every image the part produced. All output variants of a part share the
// same shell and the same #pragma config, so every variant's CONFIG word must be
// identical; checking them all also catches any accidental divergence.

#ifndef TEST_PIC_TEST_CONFIG_PIC_CORE_H
#define TEST_PIC_TEST_CONFIG_PIC_CORE_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Device label for the report line. Injected by the Makefile from the part's
// _CHIP variable rather than defaulted here: a default would make this one
// source with several callers and a fallback correct for only one of them --
// the same shape that once let the shared gpsim wrapper run PIC10F320 images on
// a p10f322 model. Here the value is a printed label rather than a simulated
// device, so a severed injection would mislabel a passing check rather than test
// the wrong part; the shape is worth refusing anyway.
#ifndef PIC_DEVICE_NAME
#  error "PIC_DEVICE_NAME must be injected: -DPIC_DEVICE_NAME from the part's _CHIP variable"
#endif

// The adapter names its part's decode table. Included below rather than by the
// adapter directly, because the table defines its assertions as functions and
// those need the CHECK harness -- and defining them where they live keeps
// __FILE__/__LINE__ in a failure pointing at the field that failed, not at this
// file's expansion site.
#ifndef PIC_CONFIG_DEVICE_HEADER
#  error "part adapter must define PIC_CONFIG_DEVICE_HEADER, e.g. \"pic/pic12f675_config.h\""
#endif

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

#include PIC_CONFIG_DEVICE_HEADER

// What the device table owes this file. Stated as guards rather than assumed,
// because a table that silently omits one of these would otherwise compile into
// a checker that verifies a different word than it claims to.
#ifndef PIC_CONFIG_WORD_ADDR
#  error "device table must define PIC_CONFIG_WORD_ADDR (program-memory WORD address)"
#endif
#ifndef PIC_CONFIG_IMPL_MASK
#  error "device table must define PIC_CONFIG_IMPL_MASK (implemented bits, from the DFP cfgdata)"
#endif
#ifndef PIC_CONFIG_DEFAULT
#  error "device table must define PIC_CONFIG_DEFAULT (erased value, from the DFP cfgdata)"
#endif
#ifndef PIC_CONFIG_EXPECTED_MASKED
#  error "device table must define PIC_CONFIG_EXPECTED_MASKED (design intent over the implemented bits)"
#endif

// Intel HEX uses BYTE addresses, and PIC program words are stored little-endian
// (low byte first), so the CONFIG word occupies two consecutive byte addresses:
//     byte_addr = word_addr * 2
#define CONFIG_BYTE_ADDR   (PIC_CONFIG_WORD_ADDR * 2u)

// Bits that are unimplemented but still appear in a built image with the erased
// value the device pack records. Derived, never written down: the two operands
// both come from the same cfgdata line, so they cannot drift apart.
#define CONFIG_UNIMPL_BITS ((uint16_t)(PIC_CONFIG_DEFAULT & ~PIC_CONFIG_IMPL_MASK))

// The full word as it appears in a built image (implemented intent + whatever
// the unimplemented bits read as).
#define EXPECTED_FULL      ((uint16_t)(PIC_CONFIG_EXPECTED_MASKED | CONFIG_UNIMPL_BITS))

//////////////////////////////////////////////////////////////////////////////
// Minimal Intel-HEX reader -- just enough to fetch the two CONFIG bytes.
//
// Record layout:  :LL AAAA TT [DD..] CC
//   LL = data byte count, AAAA = 16-bit address, TT = record type,
//   CC = two's-complement checksum of all preceding bytes.
// Types handled: 00 (data), 01 (EOF), 02 (ext segment addr), 04 (ext linear
// addr). The upper-address records keep this robust even though no image from
// any part here exceeds the 16-bit space.
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

        // Data record: see whether it covers either CONFIG byte address. A
        // second definition is ambiguous even when the byte value agrees: the
        // programmer's overlap semantics are not part of this contract.
        for (int d = 0; d < cnt; d++) {
            uint32_t abs_addr = ext_base + rec_addr + (uint32_t)d;
            if (abs_addr == CONFIG_BYTE_ADDR) {
                if (found_lo) {
                    fprintf(stderr, "FAIL: duplicate CONFIG byte address 0x%04X in '%s'\n",
                            (unsigned)CONFIG_BYTE_ADDR, path);
                    ok = 0;
                    break;
                }
                lo = (uint8_t)data[d];
                found_lo = 1;
            } else if (abs_addr == CONFIG_BYTE_ADDR + 1u) {
                if (found_hi) {
                    fprintf(stderr, "FAIL: duplicate CONFIG byte address 0x%04X in '%s'\n",
                            (unsigned)(CONFIG_BYTE_ADDR + 1u), path);
                    ok = 0;
                    break;
                }
                hi = (uint8_t)data[d];
                found_hi = 1;
            }
        }
        if (!ok) { break; }
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
    uint16_t impl = (uint16_t)(word & PIC_CONFIG_IMPL_MASK);

    printf("  %s: CONFIG=0x%04X (implemented bits 0x%04X)\n", path, word, impl);

    // --- field-by-field against the documented design intent (device table) ---
    pic_config_check_fields(impl);

    // --- whole-word cross-checks ---
    CHECK(impl == PIC_CONFIG_EXPECTED_MASKED,
          "implemented CONFIG bits must equal 0x%04X (design intent); got 0x%04X",
          (unsigned)PIC_CONFIG_EXPECTED_MASKED, (unsigned)impl);
    CHECK(word == EXPECTED_FULL,
          "built CONFIG word must equal 0x%04X (intent | unimplemented-read-1 bits); got 0x%04X",
          (unsigned)EXPECTED_FULL, (unsigned)word);

    // --- the bits whose mis-setting is invisible elsewhere (device table) ---
    pic_config_check_intent(impl);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file.hex> [<file.hex> ...]\n", argv[0]);
        return 2;
    }

    printf(PIC_DEVICE_NAME " CONFIG-word verification (word addr 0x%04X / byte 0x%04X):\n",
           (unsigned)PIC_CONFIG_WORD_ADDR, (unsigned)CONFIG_BYTE_ADDR);

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

#endif // TEST_PIC_TEST_CONFIG_PIC_CORE_H
