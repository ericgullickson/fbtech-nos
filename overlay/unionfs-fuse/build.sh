#!/usr/bin/env bash
# Build the unionfs-fuse Debian package on debian:trixie.
#
# Upstream (https://github.com/rpodgorny/unionfs-fuse) ships no debian/
# directory, so this script clones the pinned tag and adds a minimal
# debhelper-based packaging on top of it. The upstream CMake build installs
# the binary as /usr/bin/unionfs, but vyatta-cfg hard-codes the path
# /usr/bin/unionfs-fuse, so we add a symlink via debian/*.links.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="https://github.com/rpodgorny/unionfs-fuse"
UPSTREAM_TAG="v3.6"
PKG_VERSION="3.6"
PKG_REVISION="1"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    build-essential \
    fakeroot \
    debhelper \
    cmake \
    pkg-config \
    libfuse3-dev

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" src
cd src

mkdir -p debian/source

cat > debian/control <<'EOF'
Source: unionfs-fuse
Section: utils
Priority: optional
Maintainer: fbtech-nos <16152721+ericgullickson@users.noreply.github.com>
Build-Depends: debhelper-compat (= 13), cmake, pkg-config, libfuse3-dev
Standards-Version: 4.6.2
Homepage: https://github.com/rpodgorny/unionfs-fuse

Package: unionfs-fuse
Architecture: any
Depends: ${shlibs:Depends}, ${misc:Depends}
Description: Fuse-based union filesystem
 unionfs-fuse implements union mounts in user space using FUSE. It merges
 several directories into a single mount point, presenting them as one
 read-write filesystem. It is used by VyOS-derived configuration systems
 (vyatta-cfg) to implement copy-on-write configuration sessions.
 .
 This package installs the binary as /usr/bin/unionfs-fuse (a symlink to
 upstream's /usr/bin/unionfs), which is the path vyatta-cfg expects.
EOF

cat > debian/rules <<'EOF'
#!/usr/bin/make -f

%:
	dh $@ --buildsystem=cmake

override_dh_auto_configure:
	dh_auto_configure -- -DWITH_LIBFUSE3=TRUE -DCMAKE_INSTALL_PREFIX=/usr
EOF
chmod +x debian/rules

cat > debian/unionfs-fuse.links <<'EOF'
usr/bin/unionfs usr/bin/unionfs-fuse
EOF

cat > debian/copyright <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: unionfs-fuse
Source: https://github.com/rpodgorny/unionfs-fuse

Files: *
Copyright: rpodgorny and contributors
License: BSD-3-clause

License: BSD-3-clause
 See the LICENSE file in the upstream source for the full license text.
EOF

echo "10" > debian/compat.unused_placeholder && rm -f debian/compat.unused_placeholder
echo "3.0 (native)" > debian/source/format

cat > debian/changelog <<EOF
unionfs-fuse (${PKG_VERSION}-${PKG_REVISION}) unstable; urgency=medium

  * Packaged for fbtech-nos from upstream tag ${UPSTREAM_TAG}.

 -- fbtech-nos <16152721+ericgullickson@users.noreply.github.com>  $(date -R)
EOF

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
