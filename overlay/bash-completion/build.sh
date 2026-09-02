#!/usr/bin/env bash
# Build a bash-completion 2.8 Debian package on debian:trixie, pinned to
# outrank trixie's stock bash-completion (1:2.16.0-7).
#
# vyatta-bash's CLI completion engine (see overlay/vyatta-bash/build.sh and
# docs/CORE-PACKAGES.md) breaks against bash-completion 2.16 and upstream
# VyOS has never fixed this in vyatta-bash itself; it instead vendors
# Debian's own bash-completion at the debian/2.8-6 salsa tag
# (scripts/package-build/bash-completion/package.toml in vyos-build's
# rolling branch). We reproduce that here as a first-class overlay package
# so it can be published through the same apt repo.
#
# Debian's bash-completion has carried epoch 1 since long before trixie
# (VyOS's own vyatta-cfg control historically pinned "bash-completion (=
# 1:2.8-6)"), and trixie's current version is 1:2.16.0-7. dpkg version
# comparison checks the epoch first, then the upstream-version string
# *only* if the epoch is equal - and "2.8" sorts below "2.16.0" as an
# upstream-version string (8 < 16 numerically once the common "2." prefix
# is consumed). So building this at the *same* epoch (1:) as the plan
# originally sketched would NOT reliably win against 1:2.16.0-7 on a
# fresh install: apt picks the candidate with the highest full version,
# and epoch-equal comparisons fall through to the upstream-version
# component. We therefore use epoch 2 (2:2.8-6+fbtech1), which beats any
# 1:* version outright regardless of the upstream-version string, and is
# still self-evidently a "fbtech-nos build of Debian's 2.8-6" version to a
# human reading `dpkg -l`/`apt policy`.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

UPSTREAM_URL="https://salsa.debian.org/debian/bash-completion.git"
UPSTREAM_TAG="debian/2.8-6"
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

git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" src
cd src

# Bump the epoch so this always outranks trixie's stock bash-completion
# (see the comment above for why matching trixie's epoch is not enough).
CURRENT_VERSION="$(dpkg-parsechangelog -SVersion)"
UPSTREAM_NO_EPOCH="${CURRENT_VERSION#*:}"
NEW_VERSION="${PKG_EPOCH}:${UPSTREAM_NO_EPOCH}${PKG_SUFFIX}"

dch --distribution unstable --newversion "$NEW_VERSION" \
    "Rebuild for fbtech-nos: pin Debian's bash-completion 2.8-6 above trixie's 2.16 for vyatta-bash CLI completion compatibility."

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
