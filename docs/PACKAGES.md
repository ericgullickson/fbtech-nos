# fbtech-nos overlay package pipeline

fbtech-nos builds a small set of packages that are not available (or not usable) from
upstream Debian, and publishes them as a signed apt repository on GitHub Pages. Everything
else in the fork comes straight from Debian trixie.

## How it works

- `overlay/<package>/build.sh` is a self-contained script that runs **inside a
  `debian:trixie` container**. It installs its own build dependencies with `apt-get`,
  clones the pinned upstream ref, builds a real Debian package with `dpkg-buildpackage`,
  and copies the resulting `*.deb` files into `$OUT_DIR`.
- `.github/workflows/build-packages.yml` runs on `workflow_dispatch` and on pushes to
  `main`/`ci/packages` that touch `overlay/**` or the workflow itself. It has five jobs:
  - **discover**: scans `overlay/*/build.sh` and emits the full list of packages as a
    JSON array of `{name, image}` objects. `image` is the (trimmed) single-line
    contents of `overlay/<package>/image` if that file exists, otherwise
    `debian:trixie`. Adding a package is therefore just adding its directory — nothing
    in the workflow needs editing.
  - **changes** (needs `discover`): on `workflow_dispatch` this always selects every
    discovered package. On `push` it diffs `overlay/` against the previous commit and
    only selects the discovered packages whose directory actually changed, so e.g. a
    push that only touches the workflow file or another package doesn't needlessly
    rebuild and republish everything. If it can't determine a previous commit to diff
    against (first run on a branch, force-push, etc.) it falls back to building
    everything.
  - **build** (needs `changes`, skipped if `changes` selected no packages): a matrix
    job built from `changes`' `{name, image}` list via `matrix.include`, one leg per
    selected package (`fail-fast: false`), each running in that package's declared
    container image (`${{ matrix.image }}`, `debian:trixie` by default), running that
    package's `build.sh` and uploading its `*.deb` files as the artifact
    `debs-<package>`. Before building, if `overlay/<package>/deps` exists, its listed
    dependency packages are installed first — see "Cross-package build dependencies"
    below.
  - **publish** (needs `build`, `permissions: contents: write`): downloads all
    `debs-*` artifacts, assembles a `reprepro` apt repository for suite `trixie`,
    component `main`, architecture `amd64` (packages built `Architecture: all` are
    served alongside it automatically), signs `Release`/`InRelease` with the private
    key in the `APT_SIGNING_KEY` secret, and force-pushes a fresh orphan commit to the
    `gh-pages` branch containing `pool/`, `dists/`, the public keyring, `.nojekyll`,
    and `index.html`. Packages published by previous runs are copied forward into the
    new `pool/` before the current run's packages are added, so a package that is
    temporarily missing from a run's matrix is not dropped from the repository. Before
    including a freshly built `.deb`, it checks whether that exact `Package`/`Version`
    is already published and skips re-including it if so (with a log line explaining
    why) — see "Publishing is idempotent" below for why that check exists.
  - **verify** (needs `publish`, runs in `debian:trixie`): polls
    `https://ericgullickson.github.io/fbtech-nos/dists/trixie/InRelease` until GitHub
    Pages serves the new content, configures the repo exactly as an end user would,
    and does `apt-get install` plus a version-check smoke test on the built packages.

### Publishing is idempotent — bump the Debian revision to republish

`dpkg-buildpackage` builds are not byte-reproducible: the resulting `.deb` embeds
build timestamps even when nothing about the package's inputs changed. That means
re-running the pipeline without changing anything produces a `.deb` with the same
`Package`/`Version`/`Architecture` as what's already in the pool, but different file
content. `reprepro` refuses to overwrite an existing pool file with different content
under the same name (`... can only be included again, if they are the same`), which
would otherwise fail the `publish` job on every re-run.

To avoid that, the publish job checks, for each freshly built `.deb`, whether that
`Package`/`Version`/`Architecture` is already present in the repository (after
carrying forward the previous publish's pool) and **skips including it** if so,
logging why. Nothing is lost — the old build stays published — but the new build is
simply not re-added.

**This means a packaging change is only published if it bumps the Debian revision.**
If you change a package's `build.sh` (a new patch, a build-dependency fix, a
`debian/control` tweak, etc.) without also bumping its Debian revision (e.g.
`3.6-1` -> `3.6-2` for `unionfs-fuse`, or the trailing `-N` most packages' upstream
`debian/changelog` entries carry), the rebuilt `.deb` will be silently skipped by
`publish` and the repository will keep serving the old build.

## Using the repository

```sh
curl -fsSL https://ericgullickson.github.io/fbtech-nos/fbtech-nos-archive-keyring.asc \
  | sudo tee /usr/share/keyrings/fbtech-nos-archive-keyring.asc >/dev/null
echo "deb [signed-by=/usr/share/keyrings/fbtech-nos-archive-keyring.asc] https://ericgullickson.github.io/fbtech-nos trixie main" \
  | sudo tee /etc/apt/sources.list.d/fbtech-nos.list
sudo apt-get update
```

The repository is signed with an ed25519 key generated specifically for this purpose
(`fbtech-nos apt repository <16152721+ericgullickson@users.noreply.github.com>`). Its
public half is committed at `overlay/fbtech-nos-archive-keyring.asc` and served at the
repository root; the private half lives only in the `APT_SIGNING_KEY` GitHub Actions
secret and a local backup, never in git history.

## Adding a package

1. Create `overlay/<name>/build.sh`. It must:
   - Fail on error (`set -euo pipefail`).
   - Require `OUT_DIR` to be set and write the finished `*.deb` files there.
   - Install its own build dependencies via `apt-get` (the container starts bare —
     `debian:trixie` by default, or whatever `overlay/<name>/image` names).
   - Clone the upstream source at a pinned tag, branch, or commit — never a moving
     branch like `HEAD` of an unpinned default.
   - If upstream already ships a `debian/` directory, prefer building it mostly as-is;
     only patch what's necessary (see "Depends fix-ups" below). If it doesn't, add a
     minimal one (`debhelper-compat (= 13)` is the simplest starting point).
   - Run `dpkg-buildpackage -us -uc -b` and copy `../*.deb` into `$OUT_DIR`.
2. That's it for the matrix — the `discover` job picks up any `overlay/<name>/`
   directory that has a `build.sh` automatically. Nothing in the workflow needs
   editing to add a package.
3. Optionally add `overlay/<name>/image` (one line, e.g.
   `ghcr.io/ericgullickson/fbtech-nos-build:trixie`) if the package needs a heavier
   toolchain than a bare `debian:trixie` (OCaml, a full VyOS build environment, etc.).
   See "Per-package container image" below.
4. Optionally add `overlay/<name>/deps` (one dependency package name per line) if the
   build needs another overlay package's `.deb` installed first. See "Cross-package
   build dependencies" below.
5. Add it to the `apt-get install` line in the `verify` job if it should be
   smoke-tested after publish.
6. Push and watch the run with `gh run watch`. A push that only touches
   `overlay/<name>/` will build just that package; use `workflow_dispatch` (or touch
   another already-tracked package too) to exercise the full matrix.

### Per-package container image

By default every package builds in a bare `debian:trixie` container. A package can
instead declare `overlay/<name>/image`, a file containing a single line naming the
container image to build it in (e.g. a fuller VyOS-style toolchain image for
OCaml/Ada packages or ones that need `live-build`-style tooling:
`ghcr.io/ericgullickson/fbtech-nos-build:trixie`, which is public). The `discover` job
reads this file and threads the image through the matrix as `{name, image}`, so
`build`'s `container.image` is `${{ matrix.image }}` per leg.

### Cross-package build dependencies

A package can declare `overlay/<name>/deps`: one other overlay package name per line,
whose freshly built `.deb` must be installed before this package's `build.sh` runs
(e.g. a future `vyos-1x` depending on `libvyosconfig0` built by `vyos1x-config`).
Matrix legs run in parallel with no ordering guarantee between them, so this is
intentionally kept simple rather than trying to schedule builds in dependency order:
for each declared dependency, the workflow first tries to fetch that dependency's
`debs-<dep>` artifact from *this same run* (opportunistic — it only helps if that
leg happened to finish first) and falls back to installing the dependency from the
**already-published** apt repository if no same-run artifact is available yet. That
means the very first time a new dependent package is added, its dependency must
already have a successful publish behind it (or be included in the same run and win
the race) for the build to succeed; a second run will always find it via either path.

### Depends fix-ups

Several upstream VyOS `debian/control` files hard-code runtime shared-library package
names (e.g. `libpci3`, `libgnat-12`) instead of using the debhelper substitution
variables. Debian's own package names for shared libraries change between releases
(the 64-bit `time_t` transition renamed several of them), so a hard-coded name that was
correct on the release VyOS was packaged for can silently break `apt install` on a
newer Debian release. Each `build.sh` in this repo rewrites the binary package's
`Depends:` field to `${shlibs:Depends}, ${misc:Depends}` (via `sed`) right after
cloning, so `dh_shlibdeps` fills in whatever the current, correct package names are on
the build host at build time.

## Current package list

| Package | Upstream | Pinned ref | Version built | Notes |
|---|---|---|---|---|
| `unionfs-fuse` | https://github.com/rpodgorny/unionfs-fuse | tag `v3.6` | 3.6-1 | No upstream `debian/`; we add a minimal debhelper-compat 13 packaging and a `usr/bin/unionfs-fuse` symlink to upstream's `usr/bin/unionfs`, since vyatta-cfg hard-codes that path. |
| `ipaddrcheck` | https://github.com/vyos/ipaddrcheck | branch `rolling` | 1.4 | Has upstream `debian/`; built as-is apart from the `Depends:` fix-up. |
| `vyatta-biosdevname` | https://github.com/vyos/vyatta-biosdevname | branch `rolling` | 1:0.3.11+vyos2+current2 | Has upstream `debian/` (pre-dh-sequencer style rules); built as-is apart from the `Depends:` fix-up. |
| `hvinfo` | https://github.com/vyos/hvinfo | branch `rolling` | 1.2.1 | Ada, built with `gnat`/`gprbuild`. Has upstream `debian/`; `Depends: libgnat-12` is rewritten since trixie ships `libgnat-14`. |

Note: none of the four `vyos/*` upstream repositories have a branch literally named
`current`; their default/active development branch is `rolling` (verified against
`git ls-remote --heads` for each repo at the time this pipeline was built).

`vyos-1x` itself (which also produces `libvyosconfig0`, `vyos-1x-smoketest` and
`vyos-1x-vmware`) has its own recipe at `overlay/vyos-1x/` - see `docs/VYOS-1X.md`.
Unlike the four packages above it needs the full `ghcr.io/ericgullickson/fbtech-nos-build:trixie`
image rather than bare `debian:trixie`, via `overlay/vyos-1x/image`, and is not yet
wired into this workflow's static `matrix.package` list - it is meant to be picked up
once auto-discovery of `overlay/*/build.sh` and per-package `image` files lands here.
