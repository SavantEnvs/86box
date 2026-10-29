#!/usr/bin/env bash
#
# mayhem/build.sh — build the CHD fuzz harnesses (libchdr alone, and 86Box's own cdrom_chd.c on top of it)
# plus a known-answer probe. Runs inside the commit image as `mayhem` in /mayhem. No network: libchdr vendors
# lzma, miniz and zstd, and everything is compiled directly with clang (no cmake configure state to go stale).
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
#    -fno-sanitize=shift-base is the ONE UBSan relaxation, and only for these libchdr objects:
#    get_bigendian_uint32_t (libchdr_chd.c:498) builds a word as `(base[0] << 24) | ...` from a uint8_t
#    promoted to int, so any header field whose top byte is >= 0x80 trips it and halts the exec before
#    the parser gets past header_read. ASan and every other UBSan check stay halting.
for s in "${LIBSRC[@]}"; do
  echo "$CC $SANITIZER_FLAGS -fno-sanitize=shift-base $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 ${DEFS[*]} -DVERIFY_BLOCK_CRC=0 ${INC[*]} -w -c $s -o $(obj "$B/fuzz" "$s")"
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

# 3b) 86Box's own CHD front end (src/cdrom/cdrom_chd.c), compiled unmodified with the full sanitizer set,
#     against the libchdr objects above. It needs 86Box's generated version.h (a sed of version.h.in, kept
#     under the gitignored /build) and three leaf helpers from the emulator: cdrom_compute_ecc_block /
#     cdrom_crc16 / cdrom_lba_to_msf_accurate (src/cdrom/cdrom.c), crc16_* (src/utils/crc.c) and
#     cdrom_crc32 (src/utils/crc32.c). cdrom.c is the whole CD-ROM drive emulation, so it is linked with
#     --gc-sections and only those helpers survive. For that to work its object is built without SanCov
#     (the pc-table sections would keep every function alive) and with -asan-globals=0 (ASan's global
#     registration would keep every global, and through them the whole drive emulation, alive); stack,
#     heap and every UBSan check remain on for it. The harness defines only the logging sinks
#     (pclog/warning) and the chd_precache_level config global.
N="$B/chdimg"
mkdir -p "$N/include/86box"
sed -e 's/@CMAKE_PROJECT_NAME@/86Box/g' -e 's/@CMAKE_PROJECT_VERSION@/7.0/' \
    -e 's/@CMAKE_PROJECT_VERSION_MAJOR@/7/' -e 's/@CMAKE_PROJECT_VERSION_MINOR@/0/' \
    -e 's/@CMAKE_PROJECT_VERSION_PATCH@/0/' -e 's/@EMU_BUILD_NUM@/0/' \
    -e 's/@EMU_COPYRIGHT_YEAR@/2026/' -e 's/^#cmakedefine.*//' \
    src/include/86box/version.h.in > "$N/include/86box/version.h"
CINC=(-I"$N/include" -Isrc/include "${INC[@]}")
CCF=($SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 -ffunction-sections -fdata-sections -w "${CINC[@]}")
$CC "${CCF[@]}" -c src/cdrom/cdrom_chd.c -o "$N/cdrom_chd.o"
$CC "${CCF[@]}" -c src/utils/crc32.c -o "$N/crc32.o"
$CC "${CCF[@]}" -c src/utils/crc.c -o "$N/crc.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -ffunction-sections -fdata-sections -w "${CINC[@]}" \
    -mllvm -asan-globals=0 -c src/cdrom/cdrom.c -o "$N/cdrom.o"
$CC "${CCF[@]}" -c "$SRC/mayhem/chd_image_fuzz/chd_image_fuzz.c" -o "$N/harness.o"
CHDOBJS=("$N/harness.o" "$N/cdrom_chd.o" "$N/cdrom.o" "$N/crc32.o" "$N/crc.o")
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -Wl,--gc-sections "${CHDOBJS[@]}" "${FUZZOBJS[@]}" \
    "$B/lsan_off.o" -lm -o /mayhem/chd_image_fuzz
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -Wl,--gc-sections "$STANDALONE_FUZZ_MAIN" "${CHDOBJS[@]}" "${FUZZOBJS[@]}" \
    "$B/lsan_off.o" -lm -o /mayhem/chd_image_fuzz-standalone

# 4) Oracle: known-answer probe linked against a NORMAL (unsanitized, CRC-verifying) libchdr build.
for s in "${LIBSRC[@]}"; do
  echo "$CC -O2 $COVERAGE_FLAGS ${DEFS[*]} -DVERIFY_BLOCK_CRC=1 ${INC[*]} -w -c $s -o $(obj "$B/kat" "$s")"
done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'
KATOBJS=()
for s in "${LIBSRC[@]}"; do KATOBJS+=("$(obj "$B/kat" "$s")"); done
$CC -O2 $COVERAGE_FLAGS "${INC[@]}" "$SRC/mayhem/kat/chd_kat.c" "${KATOBJS[@]}" -lm -o /mayhem/chd_kat
# The same for 86Box's CHD front end: the probe opens each fixture through chd_image_open() on unsanitized
# objects (libchdr CRC verification on) and prints what the emulated drive sees.
KF=(-O2 -ffunction-sections -fdata-sections -w "${CINC[@]}")
for f in cdrom_chd:src/cdrom/cdrom_chd.c cdrom:src/cdrom/cdrom.c crc32:src/utils/crc32.c crc:src/utils/crc.c; do
  $CC "${KF[@]}" -c "${f#*:}" -o "$B/kat/img_${f%%:*}.o"
done
$CC "${KF[@]}" -c "$SRC/mayhem/kat/chd_image_kat.c" -o "$B/kat/img_kat.o"
$CC -Wl,--gc-sections "$B"/kat/img_*.o "${KATOBJS[@]}" -lm -o /mayhem/chd_image_kat
