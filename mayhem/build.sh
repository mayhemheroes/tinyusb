#!/usr/bin/env bash
#
# tinyusb/mayhem/build.sh — build hathach/tinyusb's OSS-Fuzz device harnesses as sanitized
# libFuzzer targets (+ standalone reproducers).
#
# tinyusb is a USB device/host stack. The fuzzers drive the DEVICE stack: each LLVMFuzzerTestOneInput
# splits the input into a "callback" blob (consumed by the class endpoints via tud_*_cb) and a stream
# of bytes fed to tud_int_handler()/tud_task() — i.e. attacker-controlled USB controller interrupt
# data + control-transfer / SETUP descriptors + class transfer payloads parsed by usbd.c and the
# class drivers (cdc_device.c, msc_device.c, …). Inputs are NOT raw .usb files; they are the byte
# stream the FuzzedDataProvider in test/fuzz/device/<class>/src/fuzz.cc decodes.
#
#   cdc  — CDC/ACM serial + RNDIS path: tud_task() + the tud_cdc_n_* API surface, driven over the
#          fuzzed USB interrupt/SETUP stream (test/fuzz/device/cdc).
#   msc  — Mass-Storage class: SCSI CBW/CSW + bulk transfer parsing in msc_device.c, driven over the
#          fuzzed USB interrupt/SETUP stream (test/fuzz/device/msc).
#
# We integrate the cdc + msc harnesses (no external deps). The third upstream harness (net) pulls
# the lwIP TCP/IP stack via `make get-deps` (a network fetch at build time) and is intentionally
# omitted to keep the commit image self-contained; cdc/msc are representative of the descriptor /
# control-transfer / class-data parse surface.
#
# Build contract comes from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/
# STANDALONE_FUZZ_MAIN/$OUT. We pass $SANITIZER_FLAGS through the upstream per-target Makefile so the
# tinyusb stack ITSELF (not just the harness shim) is instrumented with ASan+UBSan.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF-3 symbols required by Mayhem triage (DWARF≥4 is unreadable; clang-19 defaults to
# DWARF-5 with plain -g). Always appended AFTER $SANITIZER_FLAGS so it takes effect on every compile.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE OUT MAYHEM_JOBS

# SRC = the baked repo root (this script lives in $SRC/mayhem/).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SRC"
export SRC

HARNESS_DIR="$SRC/mayhem/harnesses"

# The upstream rules.mk compiles the tinyusb stack + harness, then links with $LIB_FUZZING_ENGINE.
# We override SANITIZER_FLAGS so the whole stack is ASan+UBSan instrumented and add
# -fsanitize=fuzzer-no-link for coverage on the library translation units (the final libFuzzer link
# supplies the runtime via $LIB_FUZZING_ENGINE; the standalone relink does not need it).
#
# rules.mk forces -fuse-ld=lld (present in the base image). It also sets -Werror; the upstream
# build.sh and net Makefile already relax a few warnings — we add -Wno-error so a benign warning in
# a stack TU compiled under our (different clang) flags cannot abort the build (does not change the
# fuzzed semantics; sanitizers stay halting).
# NOTE: pass extra flags via SANITIZER_FLAGS only — make.mk does `CFLAGS += ... $(SANITIZER_FLAGS)`,
# so a command-line `CFLAGS=` would CLOBBER the makefile's accumulated -I include paths and break
# the build. -Wno-error keeps a benign warning under our (different) clang from aborting -Werror.
MK_SAN="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -Wno-error -Wno-unused-command-line-argument"

# Standalone main object (base provides $STANDALONE_FUZZ_MAIN; fall back to our bundled copy).
STANDALONE_SRC="${STANDALONE_FUZZ_MAIN:-$HARNESS_DIR/standalone_main.c}"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_SRC" -o "$SRC/mayhem-standalone_main.o"

# Time-API shim: CFG_TUSB_OS==OPT_OS_NONE leaves tusb_time_millis_api() undefined (the application
# must provide it). Compile it once and link it into every target. We feed it to the upstream link
# via $LIB_FUZZING_ENGINE (rules.mk places that first on the link line) for the libFuzzer build, and
# add it explicitly to the standalone relink.
TIME_SHIM="$SRC/mayhem-time_shim.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HARNESS_DIR/fuzz_time_shim.c" -o "$TIME_SHIM"

build_one() {
  local name="$1" dir="test/fuzz/device/$1"
  echo "=== building harness: $name ==="
  make -C "$dir" clean >/dev/null 2>&1 || true

  # 1) libFuzzer target via the upstream Makefile (stack + harness instrumented).
  #    BOARD=spresense skips rules.mk's hard-coded `-Bstatic -lc++` link line so the C++ harness
  #    resolves against the base image's libstdc++ (it ships no libc++). BOARD is used ONLY for that
  #    gate in the fuzz makefiles, so this has no other effect.
  make -C "$dir" all -j"$MAYHEM_JOBS" \
      BOARD=spresense \
      CC="$CC" CXX="$CXX" \
      LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE $TIME_SHIM" \
      SANITIZER_FLAGS="$MK_SAN" \
      COVERAGE_FLAGS=""
  cp "$dir/_build/$name" "$OUT/$name"

  # 2) standalone reproducer: relink the SAME compiled objects against the standalone main
  #    (no libFuzzer runtime). Objects live under $dir/_build/obj/.
  local objs
  objs=$(find "$dir/_build/obj" -name '*.o' | sort)
  #    $CXX links the default C++ stdlib (libstdc++ in the base image); no -lc++.
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$SRC/mayhem-standalone_main.o" "$TIME_SHIM" $objs \
      -lm -fuse-ld=lld \
      -o "$OUT/$name-standalone"

  echo "built $name (+ standalone)"
}

build_one cdc
build_one msc

echo "build.sh complete:"
ls -la "$OUT"/cdc "$OUT"/msc "$OUT"/cdc-standalone "$OUT"/msc-standalone 2>&1 || true
