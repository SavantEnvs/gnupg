#!/usr/bin/env bash
#
# mayhem/test.sh — RUN GnuPG's own upstream test suite (`make check`), already built by
# mayhem/build.sh in the PRISTINE /tmp/gnupg-test tree. This is the real automake/gpgscm suite
# (openpgp functional tests + the common/g10 unit tests), NOT an invented oracle: it asserts
# GnuPG's behavior (encrypt/decrypt round-trips, signature verification, key listing golden
# output, …), so a "fix" that just makes the program exit(0) makes the suite FAIL.
# Emits a CTRF summary and exits non-zero on any failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

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

TB=/tmp/gnupg-test
if [ ! -f "$TB/Makefile" ]; then
  echo "test.sh: test tree $TB not built — mayhem/build.sh must run first" >&2
  emit_ctrf gnupg 0 1 0
  exit 1
fi

log=/tmp/gnupg-check.log
rc=0
make -C "$TB" check >"$log" 2>&1 || rc=$?

# Count automake's per-test verdict lines (the suite driver prints PASS:/FAIL:/SKIP: per test).
passed=$(grep -c '^PASS:' "$log" || true)
failed=$(grep -c -E '^(FAIL|XPASS|ERROR):' "$log" || true)
skipped=$(grep -c '^SKIP:' "$log" || true)

# A non-zero make check (e.g. a neutered program, or the suite aborting) that produced no explicit
# FAIL line still counts as a failure; likewise a run where nothing executed.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi

tail -40 "$log" >&2 || true
emit_ctrf gnupg "$passed" "$failed" "$skipped"
