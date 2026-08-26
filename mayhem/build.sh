#!/usr/bin/env bash
#
# mayhem/build.sh — build GnuPG's four in-process libFuzzer harnesses (decrypt/import/list/verify,
# the historical OSS-Fuzz targets) AND the project's normal test suite. Runs inside the commit
# image as `mayhem` in /mayhem. The five GnuPG library deps are already baked into /usr/local by
# mayhem/build-deps.sh (Dockerfile), so this script is air-gapped: it fetches nothing.
#
# Two independent builds from the SAME pristine upstream tree ($SRC):
#   FUZZ build  (/tmp/gnupg-fuzz): mayhem/fuzzgnupg.diff applied, ASan+UBSan (halting) + libFuzzer
#               coverage instrumentation (-fsanitize=fuzzer-no-link) so the PROJECT is instrumented,
#               DWARF<4. Produces /mayhem/fuzz_* (fuzzers) and /mayhem/fuzz_*-standalone (reproducers).
#   TEST build  (/tmp/gnupg-test): PRISTINE upstream, project's normal flags, no sanitizer/patch —
#               an honest functional oracle. mayhem/test.sh only RUNS `make check` here.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"

TARGETS="fuzz_decrypt fuzz_import fuzz_list fuzz_verify"
PREFIX=--with-libgpg-error-prefix=/usr/local\ --with-libgcrypt-prefix=/usr/local\ --with-libassuan-prefix=/usr/local\ --with-ksba-prefix=/usr/local\ --with-npth-prefix=/usr/local

# ---------------------------------------------------------------------------------------------
# 1) FUZZ build — patched, instrumented, sanitized.
# ---------------------------------------------------------------------------------------------
FB=/tmp/gnupg-fuzz
rm -rf "$FB"; mkdir -p "$FB"
tar -C "$SRC" --exclude=./.git -cf - . | tar -C "$FB" -xf -

FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"

cd "$FB"
patch -p1 < mayhem/fuzzgnupg.diff
autoreconf -fi
# ASan LeakSanitizer aborts configure's iconv probe (the probe process leaks) — disable leak
# detection for the configure run only; the built binaries are unaffected.
ASAN_OPTIONS=detect_leaks=0 ./configure \
  --enable-maintainer-mode --disable-nls --disable-doc \
  --disable-tofu --disable-gpgtar --disable-wks-tools --disable-photo-viewers \
  --disable-card-support --disable-scdaemon --disable-dirmngr --disable-gpgsm \
  --disable-g13 --disable-tpm2d --disable-keyboxd \
  $PREFIX \
  CC="$CC" CXX="$CXX" \
  CFLAGS="$FUZZ_FLAGS" CXXFLAGS="$FUZZ_FLAGS" LDFLAGS="$SANITIZER_FLAGS"
make -j"$MAYHEM_JOBS"

# g10/ builds the `gpg` executable directly from its object files — there is no libgpg.a target.
# Bundle those objects (minus the gpg/gpgv mains and the unit-test objects, which carry their own
# main()) into a convenience archive the harnesses can link against.
( cd "$FB/g10"
  objs=$(ls *.o | grep -vE '^(gpg|gpgv|t-.*|test-stubs)\.o$')
  rm -f libgpg.a
  ar rcs libgpg.a $objs
)

INC="-I$FB -I$FB/g10 -I$FB/common"
LIBS="$FB/g10/libgpg.a $FB/kbx/libkeybox.a $FB/common/libcommon.a $FB/common/libgpgrl.a $FB/regexp/libregexp.a"
SYS="-L/usr/local/lib -lgcrypt -lgpg-error -lassuan -lksba -lnpth -lz -lbz2 -lreadline"
SUPP="$SRC/mayhem/lsan_suppressions.c"

for t in $TARGETS; do
  echo ">>> harness $t (fuzzer + standalone)"
  # fuzzer binary
  $CC $FUZZ_FLAGS $INC "$SRC/mayhem/$t.c" "$SUPP" $LIBS $LIB_FUZZING_ENGINE $SYS -o "/mayhem/$t"
  # standalone run-once reproducer (no libFuzzer runtime; ASan runtime provides the cov stubs)
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION $INC \
      "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/$t.c" "$SUPP" $LIBS $SYS -o "/mayhem/$t-standalone"
done

# ---------------------------------------------------------------------------------------------
# 2) TEST build — PRISTINE upstream, normal flags (independent of the fuzz build). test.sh runs it.
# ---------------------------------------------------------------------------------------------
TB=/tmp/gnupg-test
rm -rf "$TB"; mkdir -p "$TB"
tar -C "$SRC" --exclude=./.git -cf - . | tar -C "$TB" -xf -

cd "$TB"
autoreconf -fi
env -u CFLAGS -u LDFLAGS ./configure \
  --enable-maintainer-mode --disable-nls --disable-doc \
  --disable-scdaemon --disable-dirmngr --disable-tpm2d --disable-g13 \
  $PREFIX \
  CC="$CC" CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
make -j"$MAYHEM_JOBS"

echo ">>> build.sh complete: $(echo $TARGETS | wc -w) fuzzers + standalones in /mayhem, test tree in $TB"
