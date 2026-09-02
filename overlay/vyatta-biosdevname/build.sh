#!/usr/bin/env bash
# Build the vyatta-biosdevname Debian package on debian:trixie.
#
# Upstream (https://github.com/vyos/vyatta-biosdevname) ships its own
# debian/ directory using a pre-dh-sequencer style debian/rules. We build
# it mostly as-is, only rewriting the hard-coded runtime Depends to rely on
# ${shlibs:Depends} so dh_shlibdeps resolves whatever the current Debian
# package names for libpci/zlib actually are (they have moved before, e.g.
# during the 64-bit time_t transition).
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="https://github.com/vyos/vyatta-biosdevname"
UPSTREAM_REF="rolling"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    build-essential \
    fakeroot \
    debhelper \
    autotools-dev \
    autoconf \
    automake \
    libtool \
    libpci-dev \
    zlib1g-dev

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" src
cd src

# Upstream's AM_INIT_AUTOMAKE strictness expects an INSTALL file; autoreconf
# --install/--add-missing normally supplies a boilerplate one, but make sure
# it is present in case that ever changes.
[ -f INSTALL ] || touch INSTALL

# Drop the hard-coded runtime library names; ${shlibs:Depends} covers them
# under whatever their current Debian package names are.
sed -i '/^ libpci3,$/d; /^ zlib1g,$/d' debian/control

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
