#!/usr/bin/env bash
# Build the vyatta-cfg Debian package on debian:trixie.
#
# vyatta-cfg is VyOS's C++ config backend (CStore). We build from our fork
# (ericgullickson/fbtech-nos-vyatta-cfg, branch fbtech, == upstream rolling)
# pinned to an exact commit that already carries the trixie Depends fix-ups
# mined from vyos/vyatta-cfg#104 (T7557, closed unmerged upstream):
#   - libboost-filesystem1.74.0 -> libboost-filesystem1.83.0 (Debian's
#     trixie name for the same SONAME).
#   - libapt-pkg4.12|5.0|6.0 -> add the libapt-pkg7.0 alternative trixie
#     ships.
#   - vyatta-bash (>= 4.1) / bash-completion (= 1:2.8-6) loosened to
#     unversioned, since fbtech-nos no longer hard-pins bash-completion in
#     vyatta-cfg's control (see the vyatta-bash decision in
#     docs/CORE-PACKAGES.md: we vendor bash-completion 2.8 as its own
#     overlay package with a bumped epoch instead).
# The C++ fixes from #104 (unique_ptr<char> custom deleter for strdup,
# boost::filesystem::is_regular_file, missing <cstdlib>/<algorithm>
# includes) were already present on the fbtech branch before this pipeline
# was built, so no source patching is needed here.
#
# debian/rules already passes --enable-unionfsfuse; unionfs-fuse is only
# exec'd at runtime (never linked), so it is a runtime Depends (already in
# debian/control, satisfied by our own overlay/unionfs-fuse package) and not
# a build dependency here.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="git@github.com:ericgullickson/fbtech-nos-vyatta-cfg.git"
UPSTREAM_URL_HTTPS="https://github.com/ericgullickson/fbtech-nos-vyatta-cfg.git"
PINNED_COMMIT="d3c489afa87310d584f4af03a4811ce74e447713"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    build-essential \
    fakeroot \
    debhelper \
    autotools-dev \
    dh-autoreconf \
    autoconf \
    automake \
    libtool \
    flex \
    bison \
    pkg-config \
    cpio \
    libglib2.0-dev \
    libboost-filesystem-dev \
    libapt-pkg-dev

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

# Prefer the read-only HTTPS mirror inside the build container (no SSH
# credentials there); fall back to SSH for local/dev use.
git clone "$UPSTREAM_URL_HTTPS" src || git clone "$UPSTREAM_URL" src
cd src
git checkout "$PINNED_COMMIT"

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
