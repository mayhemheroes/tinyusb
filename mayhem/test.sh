#!/usr/bin/env bash
#
# tinyusb/mayhem/test.sh — golden known-answer oracle over tinyusb's USB-descriptor parse path,
# emitting a CTRF (ctrf.io) summary. exit 0 iff every check passes.
#
# WHY a golden oracle and not the upstream suite: tinyusb's own unit tests (test/unit-test) require
# Ceedling (a Ruby gem) plus CMock/Unity code generation and a network fetch — not available in the
# self-contained commit image. Instead this builds and runs mayhem/harnesses/desc_oracle.c, which
# exercises the EXACT descriptor-walking primitives the cdc/msc fuzzers drive (tu_desc_len/type/
# subtype/next/in_bounds from src/common/tusb_common.h + tu_desc_find/find2/find3 from src/tusb.c)
# over hand-built USB configuration descriptors with BYTE-EXACT expected results.
#
# This is a PATCH-grade oracle: a no-op / exit(0) patch, or any change that alters how a descriptor
# chain is walked, breaks an assertion and fails the build. Built with NORMAL flags (no sanitizer /
# no fuzzer) so it stays an honest oracle.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

CC_BIN="${CC:-clang}"
ORACLE="$SRC/mayhem-tests/desc_oracle"
mkdir -p "$SRC/mayhem-tests"

echo "=== building descriptor golden oracle (normal flags) ==="
# NORMAL flags: no SANITIZER_FLAGS / no fuzzer. --gc-sections drops the parts of tusb.c the oracle
# does not call (the device/host stack), so we link only the descriptor helpers.
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
     "$CC_BIN" "$SRC/mayhem/harnesses/desc_oracle.c" "$SRC/src/tusb.c" \
       -I"$SRC/src" -I"$SRC/test" -I"$SRC/test/fuzz/device/cdc/src" \
       -DCFG_TUSB_MCU=OPT_MCU_FUZZ -DOPT_MCU_FUZZ=1 -D_FUZZ \
       -ffunction-sections -fdata-sections -Wl,--gc-sections \
       -O1 -o "$ORACLE"; then
  echo "oracle failed to build" >&2
  emit_ctrf "tinyusb-desc-oracle" 0 1 0
  exit 2
fi

echo "=== running descriptor golden oracle ==="
out="$("$ORACLE" 2>&1)"; rc=$?
echo "$out"

# desc_oracle.c prints a trailing "GOLDEN-ORACLE passed=N failed=M" line.
PASSED=$(printf '%s\n' "$out" | sed -n 's/.*passed=\([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*failed=\([0-9][0-9]*\).*/\1/p' | tail -1)
: "${PASSED:=0}" "${FAILED:=0}"

if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "could not parse oracle summary; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "tinyusb-desc-oracle" 1 0 0; exit 0; }
  emit_ctrf "tinyusb-desc-oracle" 0 1 0; exit 1
fi

emit_ctrf "tinyusb-desc-oracle" "$PASSED" "$FAILED"
