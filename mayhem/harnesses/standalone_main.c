/*
 * standalone_main.c — minimal run-once driver for tinyusb's libFuzzer harnesses.
 *
 * Reads a single input file and feeds it once to LLVMFuzzerTestOneInput (the entry point defined
 * by test/fuzz/device/<class>/src/fuzz.cc). Linked INSTEAD of the libFuzzer runtime to produce the
 * `-standalone` reproducer used by scripts/fuzz-smoke.sh and crash replay. No fuzzing engine.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 0) {
    fclose(f);
    return 3;
  }
  uint8_t *buf = (uint8_t *)malloc((size_t)n + 1);
  if (!buf) {
    fclose(f);
    return 3;
  }
  size_t got = (n > 0) ? fread(buf, 1, (size_t)n, f) : 0;
  fclose(f);
  LLVMFuzzerTestOneInput(buf, got);
  free(buf);
  return 0;
}
