# Milestone 4: core packages (vyatta-cfg, vyatta-bash, live-boot, live-build)

Adds the last four packages from the "must still be built and maintained" list in
`docs/FORK-ANALYSIS.md` section 7 to the overlay package pipeline described in
`docs/PACKAGES.md`: `vyatta-cfg` (config backend), `vyatta-bash` (CLI shell),
`live-boot` (VyOS's 2015-era boot/persistence fork), and `live-build` (the build-container
tool used to assemble the ISO). A fifth package, `bash-completion`, is added alongside
them as a dependency of the vyatta-bash fix (see below).

Each component fork (`ericgullickson/fbtech-nos-<component>`, branch `fbtech`, forked from
upstream `rolling`) got the minimum source/control changes needed to build on Debian
trixie; `overlay/<pkg>/build.sh` clones that fork at an exact pinned commit and runs
`dpkg-buildpackage` inside a bare `debian:trixie` container, per the contract in
`docs/PACKAGES.md`. None of the five needed the `ghcr.io/ericgullickson/fbtech-nos-build:trixie`
image or an `overlay/<pkg>/deps` file - all build-time dependencies install from plain
`debian:trixie` with `apt-get`, and none of the five need another overlay package present
at build time (unionfs-fuse is a `vyatta-cfg` *runtime* Depends only, satisfied by the
already-published `overlay/unionfs-fuse` package - it is exec'd via `/usr/bin/unionfs-fuse`
in two places, never linked).

## vyatta-cfg

Fork commit: `d3c489afa87310d584f4af03a4811ce74e447713`. Built package:
`vyatta-cfg 0.102.0+vyos2+current6` (plus `libvyatta-cfg1`, `libvyatta-cfg-dev`).

Mined `gh pr diff 104 -R vyos/vyatta-cfg` (T7557, closed unmerged upstream). Its two kinds
of changes landed differently here:

- The C++ source fixes (a custom-deleter `unique_ptr<char>` for `strdup()` results instead
  of the default `delete`-based deleter, `boost::filesystem::is_regular` ->
  `is_regular_file`, missing `<cstdlib>`/`<algorithm>` includes) were **already present**
  on our `fbtech` branch before this milestone - no action needed.
- `debian/control`'s hard-coded runtime `Depends` were not fixed yet, so this milestone
  applied them: `libboost-filesystem1.74.0` -> `libboost-filesystem1.83.0` (trixie's name
  for the same SONAME, confirmed via `qa.debian.org/madison.php?s=trixie`),
  `libapt-pkg4.12 | libapt-pkg5.0 | libapt-pkg6.0` gained a `| libapt-pkg7.0` alternative
  (trixie only ships `libapt-pkg7.0`), and `vyatta-bash (>= 4.1)` /
  `bash-completion (= 1:2.8-6)` were loosened to unversioned `vyatta-bash` /
  `bash-completion` (see the vyatta-bash section below for why we no longer hard-pin that
  exact version string here).

`debian/rules` already builds with `--enable-unionfsfuse`; no build.sh changes needed
beyond installing the existing Build-Depends list (debhelper, autotools-dev,
dh-autoreconf, autoconf/automake/libtool, flex/bison, pkg-config, cpio, libglib2.0-dev,
libboost-filesystem-dev, libapt-pkg-dev - all present in trixie at the versions
`debian/control` already requires).

Verified: `dpkg-buildpackage -us -uc -b` succeeds in a bare `debian:trixie` container via
the real `overlay/vyatta-cfg/build.sh` (fresh clone at the pinned commit). `dpkg -I` shows
runtime Depends resolved entirely through `${shlibs:Depends}`/explicit trixie package
names; `apt-get install --dry-run` against trixie + our apt repo resolves cleanly.

## vyatta-bash and the bash-completion decision

This was the hardest item in the milestone. Two separate trixie-compatibility problems
had to be solved for vyatta-bash, and they had different fixes.

### Problem 1: vyatta-bash (bash 4.1 + VyOS's restricted-shell patch) does not compile

Fork commit: `828f4974bc1126c5d454616aa33e596624d4cd76`. Built package:
`vyatta-bash 4.1-3+vyos2+current2`.

`debian/control`'s `libncurses5-dev` Build-Depends is gone from Debian (trixie ships ABI
6 `libncurses-dev`, which still provides `-lncurses`) - one-line fix.

The real problem was compilation: trixie's default `gcc` (14.x) turns
`-Wimplicit-function-declaration` and `-Wimplicit-int` from warnings into hard errors.
This bash 4.1 source relies on old-style implicit declarations across translation units
(e.g. `shell.c` calls `get_tty_state()`/`initialize_job_control()`, both defined
elsewhere in the same build with no shared prototype reaching `shell.c` - a pattern that
was completely normal C in the bash-4.x era and merely warned on older GCC). Fixed by
adding `-Wno-implicit-function-declaration -Wno-implicit-int` to `debian/rules`' hand
rolled `CFLAGS`. Also added `-fcommon`, since GCC 10 flipped the default to `-fno-common`,
which breaks this code's tentative definitions of the same global across multiple `.c`
files - this didn't actually trigger a build failure in our run (bash 4.1's globals happen
to be declared consistently enough here), but is cheap insurance against the same class of
break resurfacing with a different compiler/flag combination, and is a very well known
fix-up for building GNU-project-era C with modern GCC.

Verified: `dpkg-buildpackage -us -uc -b` succeeds via the real `overlay/vyatta-bash/build.sh`
(fresh clone at the pinned commit, bare `debian:trixie` container) and produces a working
`vbash` (`GNU bash, version 4.1.48(1)-release`). `dpkg -I` shows
`Pre-Depends: libc6 (>= 2.38), libtinfo6 (>= 6)`, `Depends: base-files (>= 2.1.12),
debianutils (>= 2.15), bash (>= 3.1)` - all satisfiable from trixie.

### Problem 2: vyatta-bash's completion engine is incompatible with bash-completion 2.16

VyOS pins `bash-completion (= 1:2.8-6)` upstream specifically because newer
bash-completion breaks vyatta-bash's CLI completion; trixie ships bash-completion 2.16.
Two paths were on the table:

- **(a) Port vyatta-bash forward** to work with bash-completion 2.16. Upstream's own
  attempt at this is a **complete replacement of vyatta-bash with stock bash 5.2.37**
  (not a compatibility patch to the 4.1 base) - mined from `gh pr view 15 -R
  vyos/vyatta-bash` ("Update vyatta-bash to bash 5.2.37", closed unmerged, >300 files
  changed) and its newer, still-unmerged continuation as of this writing:
  `vyos/vyos-build#1285` ("vbash: T7575: vyatta-bash 5.2.37 using build system", would
  archive the vyatta-bash repo entirely in favor of building stock bash from
  `scripts/package-build/`) plus its companion `vyos/vyos-1x#5412` ("Prevent re-declare
  readonly variable", open, fixing a bash-5.2-specific regression the 5.2 upgrade
  surfaces). Task https://vyos.dev/T7575 tracks this. All three are unmerged and, per
  vyos-1x#5412's existence, still shaking out new bugs as of the date this research was
  done - this is real, in-flight, cross-repo upstream work, not a small patch.
- **(b) Vendor Debian's bash-completion 2.8** as our own overlay package, matching
  `scripts/package-build/bash-completion/package.toml` on `vyos-build`'s `rolling` branch
  (`git show origin/rolling:scripts/package-build/bash-completion/package.toml`), pinned
  above trixie's version via a version-epoch trick.

**Decision: (b).** Porting a 300+-file, still-unfinished, cross-repo rewrite (and its
newer edge-case bugs) is not "the cheapest robust path" for this milestone against a
~1-day fork-and-package task. Path (b) is a direct rebuild of exactly what upstream VyOS
itself ships today (unpatched Debian bash-completion 2.8-6), it's small, and it's fully
under our control.

`overlay/bash-completion/build.sh` clones `debian/2.8-6` from
`https://salsa.debian.org/debian/bash-completion.git` and rebuilds it unmodified except
for the version string.

**Version-epoch correction to the milestone brief.** The brief suggested
`1:2.8-6+fbtech1` "with epoch matching trixie's `1:2.16.0-7`, so apt prefers ours." That
does not actually work: dpkg version comparison checks the epoch *first*, and only
falls through to comparing the upstream-version string when epochs are equal - and
`"2.8"` sorts *below* `"2.16.0"` as an upstream-version string (both start with the
literal `2.`, then `8 < 16` numerically). So at matching epoch 1, trixie's `2.16.0-7`
would still win. We build at **epoch 2** instead (`2:2.8-6+fbtech1`), which beats any
`1:*` version unconditionally. Verified directly:

```
$ dpkg -I bash-completion_2.8-6+fbtech1_all.deb | grep Version
 Version: 2:2.8-6+fbtech1

$ apt-cache policy bash-completion   # trixie main + our local repo both configured
bash-completion:
  Candidate: 2:2.8-6+fbtech1
  Version table:
     2:2.8-6+fbtech1 500
        500 file:/tmp/localrepo ./ Packages
     1:2.16.0-7 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
```

### Functional evidence

Built `vbash` and both bash-completion versions, then in a bare `debian:trixie`
container, ran (non-interactively, since real tab-completion needs a tty - this
exercises the same code path bash-completion itself uses to register and invoke a
completion function):

**Trixie's stock bash-completion 2.16 under vbash - fails:**
```
$ /bin/vbash -c "source /usr/share/bash-completion/bash_completion; echo OK"
/usr/share/bash-completion/bash_completion: line 93: conditional binary operator expected
/usr/share/bash-completion/bash_completion: line 93: syntax error near `$2'
/usr/share/bash-completion/bash_completion: line 93: `    elif [[ -v $2 && ! -v $3 ]]; then'
OK
```
Root cause: `[[ -v $2 ]]` (the `-v` test operator, which checks whether a variable is
set) was added in **bash 4.2**; vyatta-bash is bash **4.1**. This is a hard syntax error,
not a warning - `source` continues past it, but every completion function defined after
that point in the file, and every one of the dozens of files bash-completion 2.16 loads
that use `-v`, `declare -g` (added in 4.2), or other post-4.1 syntax, is silently absent
or broken. Confirmed further downstream: attempting to actually invoke a real completion
function under this combination produces a wall of `Invalid command: [_comp_deprecate_func]`
(vyatta-restricted.c's restricted-shell error - the function was never defined, so vbash's
restricted mode treats the bareword as an attempted external command) and
`declare: -g: invalid option`.

**Our bash-completion 2.8 under vbash - clean:**
```
$ /bin/vbash -c "source /usr/share/bash-completion/bash_completion && echo VBASH_SOURCED_OK_2.8"
VBASH_SOURCED_OK_2.8

$ /bin/vbash -c '
source /usr/share/bash-completion/bash_completion
_mycomplete() { COMPREPLY=(commit delete set show); }
complete -F _mycomplete myconfig
_mycomplete myconfig "" myconfig
echo COMPREPLY: ${COMPREPLY[@]}
'
COMPREPLY: commit delete set show
```

No errors, and a registered completion function runs and populates `COMPREPLY` exactly as
it would during interactive tab-completion. This does not exercise vyatta-cfg's actual
CLI completion script (`etc/bash_completion.d/vyatta-cfg`, which needs the full vyos-1x
runtime - `/opt/vyatta/share/vyatta-op/functions/interpreter/*` and friends - not
available until vyos-1x is also on trixie), but it isolates and confirms the actual
compatibility boundary: **bash-completion's own baseline bash-version requirement**,
independent of any VyOS-specific completion code.

**To reproduce/extend this check once vyos-1x is on trixie:** install `vyatta-bash`,
`bash-completion` (our 2.8 build), `vyatta-cfg`, and `vyos-1x` in one container; run
`sudo -u vyos /bin/vbash -c "source /etc/bash.bashrc; ..."` and drive the CLI completion
function found in `etc/bash_completion.d/vyatta-cfg` the same way (set `COMP_WORDS`/
`COMP_CWORD`, call the registered function, inspect `COMPREPLY`).

## live-boot

Fork commit: `d0c13b389b7fd99120ba8c91bcbcf63bcb1c6138`. Built packages: `live-boot`,
`live-boot-initramfs-tools`, `live-boot-doc`, changelog version `20151213.vyos1`
(rebuilt as `2:20151213.vyos1+fbtech1`, see version-conflict note below).

`debian/rules` is a plain `dh $@ --parallel` sequencer at compat 10 with no compiled code
(`Architecture: all`, shell/initramfs-tools hook scripts only) - it built on trixie's
debhelper (13.24) completely unmodified. No source or control changes were needed.

**Version conflict with Debian discovered during verification.** Debian trixie ships
its *own* `live-boot`/`live-boot-doc`/`live-boot-initramfs-tools` under the exact same
package names (it's the live-boot Debian itself maintains, 2025-era, and per
`docs/FORK-ANALYSIS.md` section 4 item 3 will not boot a VyOS image - the two projects
diverged a decade ago). Debian's is `1:20250815~deb13u1`. Our fork's changelog version
(`1:20151213.vyos1`) already carries the same epoch as Debian's but an older
upstream-version string, so at matching epoch apt would resolve to Debian's package on
any system that can see both repos - silently defeating the fork. `overlay/live-boot/build.sh`
now bumps the changelog to epoch 2 (`2:20151213.vyos1+fbtech1`) via `dch --newversion`
at build time, the same epoch-bump approach used for bash-completion. Verified:

```
$ apt-cache policy live-boot
live-boot:
  Candidate: 2:20151213.vyos1+fbtech1
  Version table:
     2:20151213.vyos1+fbtech1 500  (our repo)
     1:20250815~deb13u1 500        (Debian trixie main)
```

## live-build

Fork commit: `143ccb827e6aea6538c67d126a5b927e4b7501e9`. Built package: `live-build`,
changelog version `1:20210407` (rebuilt as `2:20210407+fbtech1`, see version-conflict
note below).

This is VyOS's fork of Debian's live-build **20210407** (upstream repo name
`vyos-live-build`; the fork itself is a fork of `salsa.debian.org/live-team/live-build`),
used inside the *build container* to run `lb build` when assembling the ISO - it never
ships on the target image, and it is not the vyos-1x/vyatta-cfg style CLI/config
component. `debian/control` uses `debhelper-compat (= 12)` with a plain `dh $@`
sequencer (`Architecture: all`) - it built on trixie's debhelper unmodified; `po4a` and
`gettext` (needed for the manpage translations) are both present in trixie. No source or
control changes were needed.

**Version conflict with Debian, and what the Dockerfile should change.**
`docker/Dockerfile` on the `trixie-base` branch currently does *not* use this fork at
all - it builds a completely different, much newer, **plain** Debian live-build
(`salsa.debian.org/live-team/live-build.git`, tag `debian/1%20250505+deb13u1`) from
source inside the image, applying one local patch
(`docker/patches/live-build/0001-save-package-info.patch`) for the manifest/SBOM hook.
That plain live-build is also what trixie's own apt repo ships as `live-build
1:20250505+deb13u1`.

Now that we can build `vyos-live-build` (this fork, `2021`-era, carrying whatever VyOS
patches distinguish it from plain Debian live-build - not audited line-by-line in this
milestone, out of scope; the point of this milestone was just "does it build on trixie")
and publish it in our own apt repo, `docker/Dockerfile` should be changed to
**`apt-get install live-build`** from our repo instead of the current 8-line
clone-patch-build-install `RUN` block. This removes one of the two Debian-source builds
still done from scratch in the container (the other being `debootstrap`, unaffected by
this milestone) and lets Debian's/our own package versioning track it going forward
instead of a hand-picked git tag baked into the Dockerfile.

For that `apt-get install live-build` to actually pick our fork instead of Debian's own
newer `live-build 1:20250505+deb13u1` (both would be visible in the container once the
`fbtech-nos.list` apt source is enabled - see `docker/fbtech-nos.list` in
`docker/Dockerfile`), our build needed the same epoch-bump fix as `bash-completion` and
`live-boot`: `1:20210407` (equal epoch to Debian's, older upstream-version string) would
otherwise lose. `overlay/live-build/build.sh` bumps to `2:20210407+fbtech1`. Verified:

```
$ apt-cache policy live-build
live-build:
  Candidate: 2:20210407+fbtech1
  Version table:
     2:20210407+fbtech1 500  (our repo)
     1:20250505+deb13u1 500  (Debian trixie main)
```

This Dockerfile change (swap the `RUN git clone ... && dpkg-buildpackage ...` block for
`apt-get install live-build`) is **not made in this milestone** - `docker/Dockerfile`
lives on the `trixie-base` branch, out of this worktree's allowed scope
(`overlay/<pkg>/` and `docs/CORE-PACKAGES.md` only) - and is left as an open item below.

## Verification summary

All five packages were built via their real `overlay/<pkg>/build.sh` (fresh git clone at
the pinned commit, inside a bare `debian:trixie` container, `docker run --rm -m 2500m`)
on the shared Ubuntu test host. `dpkg -I` was run on every produced `.deb`; a combined
`apt-get install --dry-run` was run for all nine binary packages
(`vyatta-cfg`, `libvyatta-cfg1`, `libvyatta-cfg-dev`, `vyatta-bash`, `bash-completion`,
`live-boot`, `live-boot-initramfs-tools`, `live-boot-doc`, `live-build`) against a
container configured with trixie main + trixie-backports + the real, already-published
`https://ericgullickson.github.io/fbtech-nos` repo + a local repo of this milestone's
freshly built `.deb`s. Every package resolved with no unsatisfied Depends and no
`Unable to locate package` errors.

| Package | Fork commit (`fbtech`) | Version built | Depends status |
|---|---|---|---|
| `vyatta-cfg` / `libvyatta-cfg1` / `libvyatta-cfg-dev` | `d3c489afa87310d584f4af03a4811ce74e447713` | `0.102.0+vyos2+current6` | All satisfiable (trixie + our repo for `unionfs-fuse`). |
| `vyatta-bash` | `828f4974bc1126c5d454616aa33e596624d4cd76` | `4.1-3+vyos2+current2` | All satisfiable (trixie). |
| `bash-completion` | n/a (Debian salsa `debian/2.8-6`, unmodified except version) | `2:2.8-6+fbtech1` | All satisfiable (trixie); outranks trixie's own `1:2.16.0-7`. |
| `live-boot` / `live-boot-initramfs-tools` / `live-boot-doc` | `d0c13b389b7fd99120ba8c91bcbcf63bcb1c6138` | `2:20151213.vyos1+fbtech1` | All satisfiable (trixie); outranks trixie's own `1:20250815~deb13u1`. |
| `live-build` | `143ccb827e6aea6538c67d126a5b927e4b7501e9` | `2:20210407+fbtech1` | All satisfiable (trixie); outranks trixie's own `1:20250505+deb13u1`. |

## Open items

1. **`docker/Dockerfile` (on `trixie-base`, out of this worktree's scope) should switch
   from building plain Debian live-build from a salsa git clone to
   `apt-get install live-build` once this package is published** - see the live-build
   section above. Whoever picks this up should also decide whether
   `docker/patches/live-build/0001-save-package-info.patch` (the manifest/SBOM hook,
   currently applied to the plain-Debian build in the Dockerfile) needs to be ported into
   this fork's `debian/` directory, since our fork's own patch set was not audited against
   that patch in this milestone.
2. **vyatta-cfg's actual CLI completion (`etc/bash_completion.d/vyatta-cfg`) has not been
   exercised end-to-end** - that requires vyos-1x's runtime (`vyatta-op`/`vyatta-cfg`
   interpreter function directories), which is not yet on trixie. The functional evidence
   in this doc isolates and confirms the bash-completion-version compatibility boundary
   only. Re-run the extended check described in the vyatta-bash section once vyos-1x is
   published.
3. **vyatta-bash's `-fcommon` addition is precautionary**, not something this build
   actually required (no `-fno-common` failure was observed) - flagging in case a future
   toolchain bump makes it load-bearing and the reason isn't obvious from `debian/rules`
   alone.
4. **This fork's own patch delta against plain Debian live-build 20210407 was not
   audited** in this milestone (only "does the existing `debian/` build on trixie" was in
   scope). Anyone relying on `vyos-live-build`'s specific patches for the ISO build
   process should diff it against `salsa.debian.org/live-team/live-build.git` at the same
   tag to see what VyOS actually changed.
5. **T7575 (upstream bash 5.2 migration) is worth re-evaluating later.** If/when
   `vyos/vyos-build#1285` and `vyos/vyos-1x#5412` land upstream, revisit whether adopting
   stock bash 5.2.37 (bash-completion 2.16-compatible out of the box) is worth dropping
   both the `vyatta-bash` fork's C-level trixie fixes and the `bash-completion` vendor
   package in favor of tracking upstream directly.
