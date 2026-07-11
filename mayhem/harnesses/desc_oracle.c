/*
 * desc_oracle.c — golden known-answer oracle for tinyusb's USB-descriptor parse path.
 *
 * This is the PATCH-grade test backing mayhem/test.sh. tinyusb's own unit suite needs Ceedling
 * (a Ruby gem + CMock generation + network), which is not available in the commit image, so instead
 * we exercise the exact descriptor-walking primitives the cdc/msc fuzzers drive — tu_desc_len /
 * tu_desc_type / tu_desc_next / tu_desc_in_bounds (inline, src/common/tusb_common.h) and
 * tu_desc_find / tu_desc_find2 / tu_desc_find3 (src/tusb.c) — over hand-built USB configuration
 * descriptors with BYTE-EXACT expected results. A no-op / exit(0) patch, or any change that alters
 * how a descriptor chain is walked, makes an assertion fail and the build/test fail.
 *
 * Built with NORMAL flags (no sanitizer / no fuzzer) so it is an honest oracle.
 */
#include "tusb.h"
#include "common/tusb_common.h"
#include "common/tusb_types.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(name, cond)                                                      \
  do {                                                                         \
    if (cond) {                                                                \
      g_pass++;                                                                \
      printf("ok   - %s\n", (name));                                           \
    } else {                                                                   \
      g_fail++;                                                                \
      printf("FAIL - %s\n", (name));                                          \
    }                                                                          \
  } while (0)

// A minimal but realistic USB configuration descriptor chain:
//   config(9) -> interface(9) -> endpoint(7) -> endpoint(7)
// Lengths/types use the standard USB values that tinyusb's parsers key on.
static const uint8_t kConfig[] = {
    // configuration descriptor: bLength=9, bDescriptorType=CONFIGURATION(0x02)
    0x09, TUSB_DESC_CONFIGURATION, 0x20, 0x00, 0x01, 0x01, 0x00, 0x80, 0x32,
    // interface descriptor: bLength=9, bDescriptorType=INTERFACE(0x04), bInterfaceClass=CDC(0x02)
    0x09, TUSB_DESC_INTERFACE, 0x00, 0x00, 0x02, TUSB_CLASS_CDC, 0x02, 0x01, 0x00,
    // endpoint descriptor: bLength=7, bDescriptorType=ENDPOINT(0x05), bEndpointAddress=0x81
    0x07, TUSB_DESC_ENDPOINT, 0x81, 0x03, 0x08, 0x00, 0x10,
    // endpoint descriptor: bLength=7, bDescriptorType=ENDPOINT(0x05), bEndpointAddress=0x02
    0x07, TUSB_DESC_ENDPOINT, 0x02, 0x02, 0x40, 0x00, 0x00,
};

int main(void) {
  const uint8_t *p = kConfig;
  const uint8_t *end = kConfig + sizeof(kConfig);

  // --- inline header primitives over the first (configuration) descriptor ---
  CHECK("tu_desc_len(config) == 9", tu_desc_len(p) == 9);
  CHECK("tu_desc_type(config) == CONFIGURATION", tu_desc_type(p) == TUSB_DESC_CONFIGURATION);
  CHECK("tu_desc_in_bounds(config)", tu_desc_in_bounds(p, end));

  // --- walk to the interface descriptor ---
  const uint8_t *iface = tu_desc_next(p);
  CHECK("next(config) -> interface offset 9", iface == kConfig + 9);
  CHECK("tu_desc_type(interface) == INTERFACE", tu_desc_type(iface) == TUSB_DESC_INTERFACE);
  CHECK("tu_desc_len(interface) == 9", tu_desc_len(iface) == 9);
  CHECK("tu_desc_subtype(interface) == 0 (bInterfaceNumber)", tu_desc_subtype(iface) == 0x00);

  // --- walk to the first endpoint ---
  const uint8_t *ep0 = tu_desc_next(iface);
  CHECK("next(interface) -> endpoint offset 18", ep0 == kConfig + 18);
  CHECK("tu_desc_type(ep0) == ENDPOINT", tu_desc_type(ep0) == TUSB_DESC_ENDPOINT);
  CHECK("tu_desc_len(ep0) == 7", tu_desc_len(ep0) == 7);

  // --- second endpoint, then end-of-chain bounds check ---
  const uint8_t *ep1 = tu_desc_next(ep0);
  CHECK("next(ep0) -> endpoint offset 25", ep1 == kConfig + 25);
  const uint8_t *past = tu_desc_next(ep1);
  CHECK("next(ep1) lands exactly at end", past == end);
  CHECK("tu_desc_in_bounds(end) is false", !tu_desc_in_bounds(end, end));

  // --- tu_desc_find: first descriptor whose byte[1] (type) matches ---
  const uint8_t *found_if = tu_desc_find(kConfig, end, TUSB_DESC_INTERFACE);
  CHECK("tu_desc_find(INTERFACE) -> offset 9", found_if == kConfig + 9);
  const uint8_t *found_ep = tu_desc_find(kConfig, end, TUSB_DESC_ENDPOINT);
  CHECK("tu_desc_find(ENDPOINT) -> first endpoint at offset 18", found_ep == kConfig + 18);
  const uint8_t *found_none = tu_desc_find(kConfig, end, 0x99);
  CHECK("tu_desc_find(missing type) -> NULL", found_none == NULL);

  // --- tu_desc_find2: match type + byte[2] (here interface's bInterfaceNumber == 0) ---
  const uint8_t *found_if2 = tu_desc_find2(kConfig, end, TUSB_DESC_INTERFACE, 0x00);
  CHECK("tu_desc_find2(INTERFACE,0) -> offset 9", found_if2 == kConfig + 9);
  const uint8_t *found_if2_miss = tu_desc_find2(kConfig, end, TUSB_DESC_INTERFACE, 0x07);
  CHECK("tu_desc_find2(INTERFACE,7) -> NULL", found_if2_miss == NULL);

  // --- tu_desc_find3: match type + byte[2] + byte[3] on the interface descriptor ---
  const uint8_t *found_if3 = tu_desc_find3(kConfig, end, TUSB_DESC_INTERFACE, 0x00, 0x00);
  CHECK("tu_desc_find3(INTERFACE,0,0) -> offset 9", found_if3 == kConfig + 9);

  printf("\nGOLDEN-ORACLE passed=%d failed=%d\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
