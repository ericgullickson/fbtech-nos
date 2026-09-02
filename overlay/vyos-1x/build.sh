#!/usr/bin/env bash
# Build the vyos-1x and libvyosconfig0 Debian packages on trixie, from the
# fbtech-nos fork of vyos-1x.
#
# Unlike the other overlay/*/build.sh scripts, this one needs the full
# vyos-1x build toolchain (OCaml/opam for libvyosconfig, syft, the whole
# vyos-1x Python build-dep list, ...), so it must run in the image named by
# overlay/vyos-1x/image (ghcr.io/ericgullickson/fbtech-nos-build:trixie),
# not bare debian:trixie.
#
# debian/rules' "make all" chain builds libvyosconfig0 by shelling out to
# libvyosconfig/Makefile's "depends" target, which does
# `opam pin add vyos1x-config https://github.com/vyos/vyos1x-config.git#<sha>`
# and the same for vyconf, via sudo. That means this script needs network
# access to github.com and a user with passwordless sudo - both already
# true of the fbtech-nos-build:trixie image (its vyos_bld user, and %sudo
# group, are NOPASSWD in /etc/sudoers) - and does the actual OCaml
# dependency fetch/build itself; nothing extra is required here for that
# part.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR must be set to a directory that will receive the .deb files}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

REPO_URL="https://github.com/ericgullickson/fbtech-nos-1x.git"
REPO_BRANCH="fbtech"
# Pinned commit on the fbtech branch (see fbtech-nos-1x's own git log for
# the matching "vyos-1x: fix trixie's pylint 3.x and Python 3.13 findings"
# commit - the first commit at which a full container build got past
# `make pylint`).
REPO_COMMIT="d72243b18441951f463419fb4c76e9a127634396"

export DEBIAN_FRONTEND=noninteractive
apt-get update

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

git clone "$REPO_URL" src
cd src
git checkout "$REPO_COMMIT"

# Verify we actually landed on the pinned commit, on the expected branch's
# history, before trusting anything else in this checkout.
resolved="$(git rev-parse HEAD)"
if [ "$resolved" != "$REPO_COMMIT" ]; then
    echo "E: expected commit $REPO_COMMIT, got $resolved" >&2
    exit 1
fi
if ! git merge-base --is-ancestor "$REPO_COMMIT" "origin/${REPO_BRANCH}"; then
    echo "E: $REPO_COMMIT is not on origin/${REPO_BRANCH}" >&2
    exit 1
fi

# Satisfy debian/control's Build-Depends. Most of these are already in the
# fbtech-nos-build:trixie image (it is built to compile vyos-1x), but
# mk-build-deps is cheap insurance against drift between the image and
# debian/control, matching how VyOS's own scripts/package-build/build.py
# does it.
mk-build-deps --install --tool "apt-get --yes --no-install-recommends" debian/control
rm -f ./*build-deps*.deb ./*build-deps*.buildinfo ./*build-deps*.changes

dpkg-buildpackage -us -uc -b

cp ../*.deb "$OUT_DIR"/
echo "Built packages:"
ls -la "$OUT_DIR"
