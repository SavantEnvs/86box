#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the libchdr known-answer probe (built by mayhem/build.sh with libchdr's normal
# flags and per-hunk CRC verification). Each fixture CHD is opened, every hunk decoded and hashed, and the
# metadata read back; the output is compared against kat/expected.txt (hashes derived independently in
# Python from the generator's byte patterns). Damaged inputs must be rejected by the library.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

KAT=/mayhem/chd_kat
FIX=mayhem/chdr_fuzz/testsuite
EXPECTED=mayhem/kat/expected.txt
[ -x "$KAT" ] || { echo "missing $KAT (build.sh should have produced it)" >&2; emit_ctrf chd-kat 0 1; exit 1; }
[ -s "$EXPECTED" ] || { echo "missing $EXPECTED" >&2; emit_ctrf chd-kat 0 1; exit 1; }

passed=0; failed=0
check() { # <name> <ok:0/1> [detail]
  if [ "$2" -eq 0 ]; then passed=$((passed+1)); echo "PASS $1"
  else failed=$((failed+1)); echo "FAIL $1${3:+: $3}"; fi
}

# 1) Known answers: one test per fixture, comparing the probe's output to the expected block.
nfix=0
for f in "$FIX"/*.chd; do
  nfix=$((nfix+1))
  n=$(basename "$f")
  want=$(awk -v key="FILE $n:" '/^FILE /{p = (index($0, key) == 1)} p' "$EXPECTED")
  got=$("$KAT" "$f" 2>&1)
  if [ -n "$want" ] && [ "$got" = "$want" ]; then check "kat $n" 0
  else check "kat $n" 1 "got: $(printf '%s' "$got" | head -3 | tr '\n' '|')"; fi
done
expect_fixtures=$(grep -c '^FILE ' "$EXPECTED")
[ "$nfix" -eq "$expect_fixtures" ]; check "fixture count ($nfix == $expect_fixtures)" $?

# 2) Damaged inputs must be rejected, not decoded.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/chdkat.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
head -c 100 "$FIX/v5_none_hd.chd" > "$tmp/trunc.chd"
out=$("$KAT" "$tmp/trunc.chd" 2>&1)
case "$out" in *"open error"*) check "truncated header rejected" 0;; *) check "truncated header rejected" 1 "$out";; esac

cp "$FIX/v5_zlib_text.chd" "$tmp/flip.chd"
size=$(stat -c %s "$tmp/flip.chd")
printf '\xff' | dd of="$tmp/flip.chd" bs=1 seek=$((size - 80)) conv=notrunc status=none
out=$("$KAT" "$tmp/flip.chd" 2>&1)
case "$out" in *"read error"*|*"open error"*) check "corrupted compressed hunk rejected" 0;; *) check "corrupted compressed hunk rejected" 1 "$out";; esac

printf 'not a chd file at all, just text\n' > "$tmp/junk.chd"
out=$("$KAT" "$tmp/junk.chd" 2>&1)
case "$out" in *"open error"*) check "non-CHD rejected" 0;; *) check "non-CHD rejected" 1 "$out";; esac

emit_ctrf chd-kat "$passed" "$failed"
