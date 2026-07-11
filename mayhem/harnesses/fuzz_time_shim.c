/*
 * fuzz_time_shim.c — supplies tusb_time_millis_api() for the host fuzz build.
 *
 * tinyusb's fuzz harnesses build with CFG_TUSB_OS == OPT_OS_NONE. In that mode src/tusb.c does NOT
 * define tusb_time_millis_api() — it is declared as a function the *application* must provide (the
 * weak default exists only for an RTOS build). The upstream OSS-Fuzz harness predates this
 * requirement, so at current HEAD the libFuzzer link is left with an undefined reference. This shim
 * provides a deterministic, monotonically-increasing millisecond counter so the device task's
 * timing calls resolve without pulling in any board/OS code. It is purely additive (no upstream file
 * is modified) and changes none of the fuzzed descriptor/transfer-parse semantics.
 */
#include <stdint.h>

uint32_t tusb_time_millis_api(void) {
  static uint32_t fake_ms = 0;
  // advance on each call so any "wait until N ms elapsed" loop terminates deterministically.
  return fake_ms++;
}
