#!/usr/bin/env bash
#
# hwloc/mayhem/build.sh — build open-mpi/hwloc's OSS-Fuzz `hwloc_fuzzer` harness as a sanitized
# libFuzzer target (+ a standalone reproducer), AND build hwloc's own test suite (normal flags)
# for mayhem/test.sh.
#
# Fuzzed surface: hwloc's Base64 codec used by the XML topology import/export path
# (hwloc/base64.c). The harness reads attacker-controlled bytes and drives:
#   hwloc_encode_to_base64(data, size, target[100], 100)  — encode the raw input into a 100B buffer
#   hwloc_decode_from_base64(NUL-terminated copy, target[100], 100) — decode it back
# Both are the routines hwloc uses to round-trip distance/cpuset blobs inside <info>/<distances>
# XML elements. The whole of libhwloc (incl. base64.c) is compiled with $SANITIZER_FLAGS so the
# fuzzed codec — not just the harness — is instrumented.
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN. hwloc is autotools: ./autogen.sh && ./configure && make. libxml2 support
# is optional and OFF here (--disable-libxml2) — the base64 codec is in core libhwloc regardless,
# and a static, dependency-light libhwloc keeps the harness self-contained.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: DWARF ≤ 3 required — clang-19 default is DWARF 5; be explicit (§6.2 item 10).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
# SanitizerCoverage instrumentation flag — must be present at COMPILE time (not just link) so the
# library code gets edge-tracing callbacks inserted by the compiler.  Without this flag libFuzzer
# sees zero edges even though the fuzzer runtime is linked in.  -fsanitize=fuzzer-no-link adds
# -fsanitize-coverage=trace-pc-guard,indirect-calls,trace-cmp without pulling in the fuzzer main.
FUZZER_NO_LINK="-fsanitize=fuzzer-no-link"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# Common configure switches: static lib only, disable every optional backend so the harness stays
# self-contained and the fuzzed code path is the in-tree base64 codec.
CONFIGURE_ARGS=( --enable-static --disable-shared --disable-libxml2 --disable-cairo
                 --disable-opencl --disable-cuda --disable-nvml --disable-rsmi
                 --disable-levelzero --disable-gl --disable-pci )

# autogen generates ./configure in the srcdir but does NOT configure it — both builds below are
# out-of-tree (VPATH) so the srcdir stays clean (autotools refuses an in-tree + VPATH mix).
[ -x ./configure ] || ./autogen.sh

# ── 1) Sanitized VPATH build of hwloc (the fuzzed base64 codec is instrumented) ────────────────
SANI_BUILD="$SRC/mayhem-build"
rm -rf "$SANI_BUILD"; mkdir -p "$SANI_BUILD"
( cd "$SANI_BUILD"
  "$SRC/configure" "${CONFIGURE_ARGS[@]}" \
    CC="$CC" CFLAGS="$SANITIZER_FLAGS $FUZZER_NO_LINK $DEBUG_FLAGS" LDFLAGS="$SANITIZER_FLAGS"
  make -j"$MAYHEM_JOBS"
)
echo "built sanitized libhwloc.a"

LIBHWLOC="$SANI_BUILD/hwloc/.libs/libhwloc.a"
LIBUTILS="$SANI_BUILD/utils/hwloc/.libs/libutils_common.a"
# Includes: srcdir headers + the VPATH build dir's generated headers (hwloc/autogen/config.h,
# private/autogen/config.h are produced by configure into $SANI_BUILD/include).
INC="-I$SANI_BUILD/include -I$SRC/include"

# ── 2) Build the harness: compile once, link twice (libFuzzer target + standalone reproducer) ──
$CC $SANITIZER_FLAGS $FUZZER_NO_LINK $DEBUG_FLAGS $INC -c "$HARNESS_DIR/hwloc_fuzzer.c" -o "$SRC/hwloc_fuzzer.o"

LINK_LIBS=( -Wl,--start-group "$LIBHWLOC" )
[ -f "$LIBUTILS" ] && LINK_LIBS+=( "$LIBUTILS" )
LINK_LIBS+=( -Wl,--end-group -lm )

# libFuzzer target -> /mayhem/hwloc_fuzzer  (clang++ for the C++ libFuzzer runtime)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -o /mayhem/hwloc_fuzzer \
    "$SRC/hwloc_fuzzer.o" $LIB_FUZZING_ENGINE "${LINK_LIBS[@]}"

# Standalone reproducer (no libFuzzer runtime; reads one input file, runs once, natural crash).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -o /mayhem/hwloc_fuzzer-standalone \
    "$SRC/hwloc_fuzzer.o" "$SRC/standalone_main.o" "${LINK_LIBS[@]}"

echo "built hwloc_fuzzer (+ standalone)"

# ── 3) Build hwloc's OWN test suite with NORMAL flags in a separate tree so test.sh only RUNS it.
#       hwloc's tests/hwloc/*.c are real assertion / known-answer tests (bitmap ops, distances,
#       object lookups, XML round-trips against tests/hwloc/xml/*.xml). Building here (not in
#       test.sh) keeps test.sh an honest PATCH oracle and avoids sanitizer/benign-UB noise. ───────
TESTDIR="$SRC/mayhem-tests"
rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"
( cd "$TESTDIR"
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    "$SRC/configure" "${CONFIGURE_ARGS[@]}" CC="$CC"
  # Build libhwloc + all default targets (lib, utils including lstopo-no-graphics) with normal flags.
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -j"$MAYHEM_JOBS"
  # Pre-build the top-level check programs WITHOUT running them (TESTS="" = build phase only).
  # automake's check-TESTS rule depends on $(check_PROGRAMS); with TESTS="" the dep-build fires
  # but no test executable is invoked. Drop -j to avoid parallel-build races in the test dir.
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    make -C tests/hwloc check-TESTS TESTS="" 2>&1 || true
) && echo "built hwloc test suite (normal flags) in mayhem-tests/" \
  || echo "WARNING: test suite build step exited — test.sh will compile-on-first-run" >&2

echo "build.sh complete:"
ls -la /mayhem/hwloc_fuzzer /mayhem/hwloc_fuzzer-standalone 2>&1 || true
