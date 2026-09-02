#!/usr/bin/env bash
# Build the hvinfo Debian package on debian:trixie.
#
# Upstream (https://github.com/vyos/hvinfo) is Ada, built with gnat/gprbuild,
# and ships its own debian/ directory. We build it mostly as-is, only
# rewriting the hard-coded "Depends: libgnat-12" (Debian trixie ships
# libgnat-14) to rely on ${shlibs:Depends} so dh_shlibdeps resolves whatever
# the current GNAT runtime package is.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="https://github.com/vyos/hvinfo"
UPSTREAM_REF="rolling"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    build-essential \
    fakeroot \
    debhelper \
    gnat \
    gprbuild

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" src
cd src

sed -i \
    's/^Depends: libgnat-12$/Depends: ${shlibs:Depends}, ${misc:Depends}/' \
    debian/control

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
