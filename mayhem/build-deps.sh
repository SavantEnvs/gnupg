#!/usr/bin/env bash
#
# mayhem/build-deps.sh — build GnuPG's five GnuPG-project library dependencies from source
# (git master is ahead of every distro: gnupg master needs libgpg-error >= 1.56,
# libgcrypt >= 1.11, libassuan >= 3.0). Run ONCE as root by mayhem/Dockerfile; installs
# static libs into /usr/local so mayhem/build.sh is fully air-gapped afterwards.
# Every clone is pinned to an exact commit.
set -euo pipefail

: "${MAYHEM_JOBS:=$(nproc)}"
WORK=/tmp/gnupg-deps
mkdir -p "$WORK"

# name  pinned-commit  extra-configure-flags
DEPS='
libgpg-error ad87550c82463d9a2cc51052ac6c6376555e6a94
npth d4e067d96c5e868e5208613f37dfacaab4298d7c
libassuan 92587b7bf5ffbdd34e2139f3563211cd2d04f652
libksba 7d1ed87ff36943835fdadc6bf4c7cb47f2b4a00e
libgcrypt 35f4e5abf22c8a1cb07314914d29b11c63decb5b --disable-asm
'

echo "$DEPS" | while read -r name sha extra; do
  [ -n "$name" ] || continue
  echo ">>> building $name @ $sha"
  # full clone: the GnuPG autotools version machinery runs `git describe`, which needs tags
  git clone "https://github.com/gpg/$name.git" "$WORK/$name"
  git -C "$WORK/$name" checkout -q "$sha"
  (
    cd "$WORK/$name"
    autoreconf -fi
    ./configure --enable-static --disable-shared --disable-doc --disable-nls \
                --with-libgpg-error-prefix=/usr/local ${extra:-}
    make -j"$MAYHEM_JOBS"
    make install
  )
done

rm -rf "$WORK"
ldconfig
echo ">>> all gnupg deps installed to /usr/local"
