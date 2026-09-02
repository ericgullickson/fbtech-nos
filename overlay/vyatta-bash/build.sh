#!/usr/bin/env bash
# Build the vyatta-bash Debian package on debian:trixie.
#
# vyatta-bash is VyOS's CLI shell: bash 4.1 plus a VyOS restricted-shell
# patch (vyatta-restricted.c) and a custom, hand-written debian/rules (not
# the dh sequencer) that builds bash from a vendored tarball-in-tree.
#
# bash-completion decision (see docs/CORE-PACKAGES.md for the full writeup):
# trixie ships bash-completion 2.16, which is incompatible with vyatta-bash's
# ancient completion engine (VyOS pins bash-completion 2.8 upstream for this
# reason). Upstream's own fix is an in-flight, unmerged, cross-repo rewrite
# to bash 5.2.37 (vyos/vyatta-bash#15, vyos/vyos-build#1285,
# vyos/vyos-1x#5412 - all open/closed-unmerged as of this writing, plus a
# bash-5.2-specific bug (readonly re-declare) still being fixed). Porting
# that is not achievable in this milestone, so we take path (b): vendor
# Debian's bash-completion 2.8-6 as our own overlay package (see
# overlay/bash-completion/build.sh) with a bumped epoch so apt always
# prefers it over trixie's 2.16. vyatta-bash itself only needs two fixes to
# compile and run on trixie:
#   - Build-Depends: libncurses5-dev (gone from Debian) -> libncurses-dev
#     (trixie's ABI 6 ncurses dev package; still provides -lncurses).
#   - CFLAGS: trixie's gcc 14 turns implicit-function-declaration and
#     implicit-int into hard errors (this bash 4.1 source relies on
#     old-style cross-TU implicit declarations); -fcommon since gcc 10
#     defaults to -fno-common, breaking this code's tentative global
#     definitions. See the fbtech branch commit for the full rationale.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="git@github.com:ericgullickson/fbtech-nos-vyatta-bash.git"
UPSTREAM_URL_HTTPS="https://github.com/ericgullickson/fbtech-nos-vyatta-bash.git"
PINNED_COMMIT="828f4974bc1126c5d454616aa33e596624d4cd76"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    build-essential \
    fakeroot \
    debhelper \
    autoconf \
    automake \
    autotools-dev \
    patch \
    bison \
    libncurses-dev \
    locales

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

git clone "$UPSTREAM_URL_HTTPS" src || git clone "$UPSTREAM_URL" src
cd src
git checkout "$PINNED_COMMIT"

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
