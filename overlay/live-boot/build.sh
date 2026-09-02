#!/usr/bin/env bash
# Build the live-boot Debian package on debian:trixie.
#
# live-boot is VyOS's 2015-era fork of Debian's live-boot, carrying the
# VyOS persistence/image layout (/boot/<image>/rw, per-image squashfs,
# `add system image` upgrades). Debian's own live-boot has diverged for a
# decade and will not boot a VyOS image, so this fork is kept permanently
# (docs/FORK-ANALYSIS.md section 4, item 3).
#
# debian/rules is a plain `dh $@ --parallel` sequencer at compat 10 with no
# compiled code (Architecture: all, shell/initramfs-tools hook scripts
# only), so it builds on trixie's debhelper (13.24) unmodified - no source
# or control changes were needed for this milestone. dh_auto_install splits
# the tree into the three binary packages upstream's control already
# defines: live-boot, live-boot-initramfs-tools, live-boot-doc.
#
# Version conflict with Debian: trixie's own live-boot/live-boot-doc/
# live-boot-initramfs-tools packages (Debian ships its own, much newer,
# live-boot under the exact same names) are at 1:20250815~deb13u1. Our
# fork's changelog version (1:20151213.vyos1) has the *same* epoch (1) but
# an older upstream-version string ("20151213..." < "20250815..."), so at
# equal epoch apt would silently prefer Debian's genuine (and
# VyOS-image-incompatible, per docs/FORK-ANALYSIS.md section 4 item 3)
# live-boot on any install that can see both. We bump to epoch 2 here
# (2:20151213.vyos1+fbtech1) so ours always wins regardless of the
# upstream-version string, same approach as overlay/bash-completion/build.sh.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="git@github.com:ericgullickson/fbtech-nos-live-boot.git"
UPSTREAM_URL_HTTPS="https://github.com/ericgullickson/fbtech-nos-live-boot.git"
PINNED_COMMIT="d0c13b389b7fd99120ba8c91bcbcf63bcb1c6138"
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
    "Rebuild for fbtech-nos: outrank Debian trixie's own live-boot (VyOS-image-incompatible for our purposes) so apt always prefers this fork."

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
