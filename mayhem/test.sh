#!/usr/bin/env bash
#
# hwloc/mayhem/test.sh — RUN hwloc's own test suite (built by mayhem/build.sh with normal flags)
# and emit a CTRF summary. exit 0 iff no test failed.
#
# BEHAVIORAL oracle (§6.3, anti-reward-hacking): this script DIRECTLY runs hwloc_bitmap_string
# and greps its stdout for known-answer strings like "empty cpuset converted back and forth, ok".
# When the binary is neutered to exit(0) by the sabotage library, it produces NO output at all,
# so the greps fail → FAIL_TOTAL > 0 → emit_ctrf exits non-zero → sabotage is DETECTED.
#
# A pure "make check" oracle is reward-hackable because automake captures test stdout to a .log
# file and treats exit(0) as PASS regardless of content. This script directly invokes the binary
# to inspect its stdout, bypassing automake's log capture.
#
# build.sh pre-builds the test programs via `make check-TESTS TESTS=""`. If a binary is missing,
# `make check-TESTS` in this script will compile it (acceptable; the behavioral grep still fires).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

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

if [ ! -d "$BUILDDIR/tests/hwloc" ]; then
  echo "missing $BUILDDIR/tests/hwloc — run mayhem/build.sh first" >&2
  emit_ctrf "hwloc-make-check" 0 1 0; exit 2
fi

# ── Behavioral oracle: DIRECTLY run hwloc_bitmap_string and grep its stdout ─────────────────────
# This binary prints "empty cpuset converted back and forth, ok", "system cpuset is 0x...", etc.
# to stdout during a correct run. Automake captures test stdout to .log files (hidden from make
# output), so we CANNOT use the make check summary for a behavioral oracle — we must run the
# binary DIRECTLY and inspect what it prints.
#
# When the sabotage library neuters every non-system binary to exit(0), the binary exits
# immediately with NO output → greps fail → BEHAVIORAL_FAILED > 0 → test.sh exits non-zero.
BEHAVIORAL_PASSED=0
BEHAVIORAL_FAILED=0

BSTR_BIN="$BUILDDIR/tests/hwloc/hwloc_bitmap_string"
if [ ! -x "$BSTR_BIN" ]; then
  # Binary not pre-built — try to build it now (will succeed in a live container, fail in sabotage).
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    make -C "$BUILDDIR/tests/hwloc" check-TESTS TESTS="" 2>/dev/null || true
fi

if [ ! -x "$BSTR_BIN" ]; then
  echo "ORACLE FAIL: $BSTR_BIN not found and could not be built" >&2
  BEHAVIORAL_FAILED=$(( BEHAVIORAL_FAILED + 3 ))
else
  # Run the binary directly (cd to tests dir so VPATH-relative includes work).
  bstr_out="$( cd "$BUILDDIR/tests/hwloc" && "$BSTR_BIN" 2>/dev/null )" || true
  echo "=== hwloc_bitmap_string stdout (behavioral oracle) ==="
  printf '%s\n' "$bstr_out" | head -6

  # Oracle check 1: empty cpuset round-trip — printed only when the library executes
  if printf '%s\n' "$bstr_out" | grep -qF "empty cpuset converted back and forth, ok"; then
    echo "ORACLE PASS: hwloc_bitmap_string: empty cpuset round-trip confirmed"
    BEHAVIORAL_PASSED=$(( BEHAVIORAL_PASSED + 1 ))
  else
    echo "ORACLE FAIL: expected 'empty cpuset converted back and forth, ok' in stdout" >&2
    BEHAVIORAL_FAILED=$(( BEHAVIORAL_FAILED + 1 ))
  fi

  # Oracle check 2: full cpuset round-trip
  if printf '%s\n' "$bstr_out" | grep -qF "full cpuset converted back and forth, ok"; then
    echo "ORACLE PASS: hwloc_bitmap_string: full cpuset round-trip confirmed"
    BEHAVIORAL_PASSED=$(( BEHAVIORAL_PASSED + 1 ))
  else
    echo "ORACLE FAIL: expected 'full cpuset converted back and forth, ok' in stdout" >&2
    BEHAVIORAL_FAILED=$(( BEHAVIORAL_FAILED + 1 ))
  fi

  # Oracle check 3: system cpuset printed (topology init + asprintf call)
  if printf '%s\n' "$bstr_out" | grep -qE "^system cpuset is 0x[0-9a-f,\.]+"; then
    echo "ORACLE PASS: hwloc_bitmap_string: system cpuset printed"
    BEHAVIORAL_PASSED=$(( BEHAVIORAL_PASSED + 1 ))
  else
    echo "ORACLE FAIL: expected 'system cpuset is 0x...' in stdout" >&2
    BEHAVIORAL_FAILED=$(( BEHAVIORAL_FAILED + 1 ))
  fi
fi

# ── Run make check-TESTS: top-level tests/hwloc only (no xml/ports subdirs) ─────────────────────
# Using check-TESTS (not check) avoids recursion into subdirectories that require host-specific
# tooling or can't create .trs files in the container environment.
# Environment-dependent test (needs real NUMA): skip it.
ENV_SKIP="hwloc_get_area_memlocation"

PRINT_MK="$(mktemp)"; printf 'mayhem_print:\n\t@echo $(TESTS)\n' > "$PRINT_MK"
ALL_TESTS="$(env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
              make -C "$BUILDDIR/tests/hwloc" -f Makefile -f "$PRINT_MK" \
                   --no-print-directory mayhem_print 2>/dev/null || true)"
rm -f "$PRINT_MK"
RUN_TESTS=""; SKIPPED_ENV=0
for t in $ALL_TESTS; do
  case " $ENV_SKIP " in
    *" $t "*) SKIPPED_ENV=$((SKIPPED_ENV+1)) ;;
    *) RUN_TESTS="$RUN_TESTS $t" ;;
  esac
done

echo "=== running 'make check-TESTS' in $BUILDDIR/tests/hwloc (skipping env-gated: $ENV_SKIP) ==="
suite_out="$(env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
               make -C "$BUILDDIR/tests/hwloc" check-TESTS TESTS="${RUN_TESTS# }" 2>&1)"; suite_rc=$?
echo "$suite_out"

# Parse automake summary block.
PASS=$(printf '%s\n' "$suite_out"  | sed -n 's/^#[[:space:]]*PASS:[[:space:]]*\([0-9][0-9]*\).*/\1/p'  | tail -1)
SKIP=$(printf '%s\n' "$suite_out"  | sed -n 's/^#[[:space:]]*SKIP:[[:space:]]*\([0-9][0-9]*\).*/\1/p'  | tail -1)
XFAIL=$(printf '%s\n' "$suite_out" | sed -n 's/^#[[:space:]]*XFAIL:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
FAIL=$(printf '%s\n' "$suite_out"  | sed -n 's/^#[[:space:]]*FAIL:[[:space:]]*\([0-9][0-9]*\).*/\1/p'  | tail -1)
XPASS=$(printf '%s\n' "$suite_out" | sed -n 's/^#[[:space:]]*XPASS:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
ERROR=$(printf '%s\n' "$suite_out" | sed -n 's/^#[[:space:]]*ERROR:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
: "${PASS:=0}" "${SKIP:=0}" "${XFAIL:=0}" "${FAIL:=0}" "${XPASS:=0}" "${ERROR:=0}"

SUITE_PASS=$(( PASS + XFAIL ))
SUITE_FAIL=$(( FAIL + XPASS + ERROR ))
SKIP=$(( SKIP + SKIPPED_ENV ))

if [ "$(( SUITE_PASS + SUITE_FAIL + SKIP ))" -eq 0 ]; then
  echo "could not parse automake test summary; using make exit code $suite_rc" >&2
  if [ "$suite_rc" -eq 0 ]; then SUITE_PASS=1; else SUITE_FAIL=1; fi
fi

PASS_TOTAL=$(( BEHAVIORAL_PASSED + SUITE_PASS ))
FAIL_TOTAL=$(( BEHAVIORAL_FAILED + SUITE_FAIL ))

emit_ctrf "hwloc-make-check" "$PASS_TOTAL" "$FAIL_TOTAL" "$SKIP"
