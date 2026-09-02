#!/usr/bin/env bash
# Build the ipaddrcheck Debian package on debian:trixie.
#
# Upstream (https://github.com/vyos/ipaddrcheck) ships its own debian/
# directory, so we build it mostly as-is. We do rewrite the Depends field
# of the binary package to rely purely on ${shlibs:Depends}/${misc:Depends}
# instead of the hard-coded runtime library package names upstream lists,
# since Debian's shared-library package names can be renamed between
# releases (e.g. the 64-bit time_t transition) and dh_shlibdeps always
# resolves to whatever is actually current on the build host.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="https://github.com/vyos/ipaddrcheck"
UPSTREAM_REF="rolling"

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
    libtool \
    pkg-config \
    libpcre2-dev \
    libcidr-dev \
    check

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" src
cd src

# Replace the hard-coded runtime library names with the debhelper
# substitution variables so dh_shlibdeps picks the correct current names.
sed -i \
    's/^Depends: .*/Depends: ${shlibs:Depends}, ${misc:Depends}/' \
    debian/control

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
