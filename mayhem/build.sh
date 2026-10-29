#!/usr/bin/env bash
#
# mayhem/build.sh — build the libchdr (86Box's CHD disc-image reader) fuzz harness + a known-answer probe.
# Runs inside the commit image as `mayhem` in /mayhem. No network: libchdr vendors lzma, miniz and zstd,
# and everything is compiled directly with clang (no cmake configure state to go stale).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
CHDR=src/cdrom/libchdr
B="$SRC/build"          # /build is gitignored upstream, so the clean-tree check removes it
rm -rf "$B"
mkdir -p "$B/fuzz" "$B/kat"

LIBSRC=(
  $CHDR/src/libchdr_bitstream.c $CHDR/src/libchdr_cdrom.c $CHDR/src/libchdr_chd.c
  $CHDR/src/libchdr_codec_cdfl.c $CHDR/src/libchdr_codec_cdlz.c $CHDR/src/libchdr_codec_cdzl.c
  $CHDR/src/libchdr_codec_cdzs.c $CHDR/src/libchdr_codec_flac.c $CHDR/src/libchdr_codec_huff.c
  $CHDR/src/libchdr_codec_lzma.c $CHDR/src/libchdr_codec_zlib.c $CHDR/src/libchdr_codec_zstd.c
  $CHDR/src/libchdr_flac.c $CHDR/src/libchdr_huffman.c
  $CHDR/deps/lzma-25.01/src/LzmaDec.c $CHDR/deps/miniz-3.1.1/miniz.c $CHDR/deps/zstd-1.5.7/zstddeclib.c
)
INC=(-I"$CHDR/include" -I"$CHDR/deps/lzma-25.01/include" -I"$CHDR/deps/miniz-3.1.1" -I"$CHDR/deps/zstd-1.5.7")
# The same defines libchdr's CMakeLists uses for its bundled-deps build (WITH_SYSTEM_ZLIB/ZSTD=OFF).
DEFS=(-DWANT_RAW_DATA_SECTOR=1 -DWANT_SUBCODE=1 -DMINIZ_NO_ARCHIVE_APIS -DMINIZ_NO_DEFLATE_APIS
      -DMINIZ_NO_STDIO -DMINIZ_NO_TIME)

obj() { echo "$1/$(echo "${2#$CHDR/}" | tr / _).o"; }

# 1) Sanitized + SanCov-instrumented library for the fuzz targets. Per-hunk CRC verification is
#    disabled here so mutated hunk payloads reach the codecs instead of dying at the CRC check; the
#    oracle build below keeps libchdr's default (CRC verified).
for s in "${LIBSRC[@]}"; do
  echo "$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 ${DEFS[*]} -DVERIFY_BLOCK_CRC=0 ${INC[*]} -w -c $s -o $(obj "$B/fuzz" "$s")"
done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'

# 2) LeakSanitizer off at build time (docs/rules/c.md); ASan/UBSan stay on.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"

FUZZOBJS=()
for s in "${LIBSRC[@]}"; do FUZZOBJS+=("$(obj "$B/fuzz" "$s")"); done

# 3) Harness: libFuzzer binary + run-once standalone reproducer.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 ${DEFS[@]} -DVERIFY_BLOCK_CRC=0 "${INC[@]}" -w \
    $LIB_FUZZING_ENGINE "$SRC/mayhem/chdr_fuzz/chdr_fuzz.c" "${FUZZOBJS[@]}" "$B/lsan_off.o" -lm -o /mayhem/chdr_fuzz
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 ${DEFS[@]} -DVERIFY_BLOCK_CRC=0 "${INC[@]}" -w \
    "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/chdr_fuzz/chdr_fuzz.c" "${FUZZOBJS[@]}" "$B/lsan_off.o" -lm \
    -o /mayhem/chdr_fuzz-standalone

# 4) Oracle: known-answer probe linked against a NORMAL (unsanitized, CRC-verifying) libchdr build.
for s in "${LIBSRC[@]}"; do
  echo "$CC -O2 $COVERAGE_FLAGS ${DEFS[*]} -DVERIFY_BLOCK_CRC=1 ${INC[*]} -w -c $s -o $(obj "$B/kat" "$s")"
done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'
KATOBJS=()
for s in "${LIBSRC[@]}"; do KATOBJS+=("$(obj "$B/kat" "$s")"); done
$CC -O2 $COVERAGE_FLAGS "${INC[@]}" "$SRC/mayhem/kat/chd_kat.c" "${KATOBJS[@]}" -lm -o /mayhem/chd_kat
