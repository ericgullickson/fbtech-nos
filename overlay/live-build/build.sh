#!/usr/bin/env bash
# Build the live-build Debian package on debian:trixie.
#
# This is VyOS's fork of Debian's live-build 20210407 (upstream repo name
# vyos-live-build), used inside the *build container* to assemble the ISO
# via `lb build` - it never ships on the target image. It is not the same
# thing as the much newer plain-Debian live-build that
# docker/Dockerfile currently builds from source (see docs/CORE-PACKAGES.md
# for the follow-up this implies for that Dockerfile).
#
# debian/control uses debhelper-compat (= 12) with a plain `dh $@`
# sequencer (Architecture: all, Perl/shell only - see debian/rules), so it
# builds unmodified on trixie's debhelper (13.24); po4a/gettext (for the
# manpage translations) are both present in trixie. No source or control
# changes were needed for this milestone.
#
# Version conflict with Debian: trixie ships its own live-build (a plain,
# far newer build of the same upstream project - the very build our own
# trixie-base docker/Dockerfile currently compiles from a salsa git clone)
# at 1:20250505+deb13u1 - epoch 1. Our fork's changelog version (1:20210407,
# also epoch 1, but an older upstream-version string) would lose an
# epoch-equal comparison to Debian's. We bump to
# epoch 2 here (2:20210407+fbtech1) so `apt-get install live-build` in the
# Dockerfile always resolves to our VyOS-patched fork once it is switched
# to install from our repo (see docs/CORE-PACKAGES.md for that follow-up),
# the same approach as overlay/bash-completion and overlay/live-boot.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="git@github.com:ericgullickson/fbtech-nos-live-build.git"
UPSTREAM_URL_HTTPS="https://github.com/ericgullickson/fbtech-nos-live-build.git"
PINNED_COMMIT="143ccb827e6aea6538c67d126a5b927e4b7501e9"
PKG_EPOCH="2"
PKG_SUFFIX="+fbtech1"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    build-essential \
    fakeroot \
    debhelper \
    po4a \
    gettext \
    devscripts

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

git clone "$UPSTREAM_URL_HTTPS" src || git clone "$UPSTREAM_URL" src
cd src
git checkout "$PINNED_COMMIT"

CURRENT_VERSION="$(dpkg-parsechangelog -SVersion)"
UPSTREAM_NO_EPOCH="${CURRENT_VERSION#*:}"
NEW_VERSION="${PKG_EPOCH}:${UPSTREAM_NO_EPOCH}${PKG_SUFFIX}"
dch --distribution unstable --newversion "$NEW_VERSION" \
    "Rebuild for fbtech-nos: outrank Debian trixie's own live-build so the build container installs this VyOS-patched fork."

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
