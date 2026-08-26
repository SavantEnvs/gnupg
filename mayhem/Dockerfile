# syntax=docker/dockerfile:1.7
#
# Commit-image for gnupg. Builds on the org C/C++ base (clang/llvm + libFuzzer + build contract).
# GnuPG git-master needs bleeding-edge GnuPG libraries (libgpg-error>=1.56, libgcrypt>=1.11,
# libassuan>=3.0) that no distro ships, so we build the five deps from source (pinned commits) into
# /usr/local — after that mayhem/build.sh is fully air-gapped.
FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Extra apt packages for the build (bzip2/readline dev + sqlite for the tofu-enabled test build).
# Pin apt to SOURCE_DATE_EPOCH for reproducibility when provided.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libbz2-dev libreadline-dev libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Build + install the five GnuPG library dependencies (pinned commits) into /usr/local.
COPY --chown=2000:2000 mayhem/build-deps.sh /tmp/build-deps.sh
RUN MAYHEM_JOBS="${MAYHEM_JOBS:-$(nproc)}" bash /tmp/build-deps.sh && rm -f /tmp/build-deps.sh

# Full repo (incl. .git) enters at /mayhem; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
