# Milestone 3: trixie build base

Retargets the image builder from Debian bookworm with a self-built kernel to
Debian trixie with Debian's stock kernel, and trims the self-built package
set (`scripts/package-build/`) down to the overlay decided in
`docs/FORK-PLAN.md` / `docs/FORK-ANALYSIS.md` section 7.

This milestone does **not** produce a bootable image. `vyos-1x` and the rest
of the overlay are not published for trixie yet (that is milestone 2's
package pipeline and milestone 4's `vyos-1x` fork). The goal here is the
Debian-side plumbing: base image, kernel, package lists, hooks, and to
observe and record exactly where a trixie ISO build currently stops.

## What changed

### `docker/Dockerfile`

- Base image: `debian:bookworm-slim` -> `debian:trixie-slim`; `VERSION_ID`
  fallback `"12"` -> `"13"`; OCI labels repointed at
  `github.com/ericgullickson/fbtech-nos` and the image title/description
  renamed to `fbtech-nos-build`.
- Removed toolchain only needed for dropped packages:
  - The `bookworm-backports` + `meson` block (was only there to build Kea;
    Kea is now installed straight from Debian, not self-built).
  - The Go 1.23 toolchain and its `PATH` wiring (was only for
    telegraf/Prometheus exporters, both dropped).
  - The `i2util` build (OWAMP/TWAMP, dropped).
  - The `vyos-cloud-init` Python test dependency block (cloud-init dropped).
    Three of those packages (`python3-pep8`, `python3-unittest2`,
    `python3-contextlib2`) no longer exist in trixie anyway, which is how
    this was found - see "Package name changes" below.
  - `sbsigntool` (Secure Boot kernel signing, dropped; see hooks below).
- Package name/version fixes for trixie (see next section): `qemu-kvm`
  removed, `qemu-system-aarch64` -> `qemu-system-arm`.
- `vyos-dev.list` / `vyos-dev.key` (VyOS's own repo + static key) replaced
  by `docker/fbtech-nos.list` (`deb [signed-by=...] https://ericgullickson.github.io/fbtech-nos trixie main`)
  and a `curl` fetch of the real keyring
  (`fbtech-nos-archive-keyring.asc`, published by the package-build
  pipeline on another branch) at image build time, with a fallback that
  disables the repo file (renames it to `.disabled`) if the keyring is not
  live yet, so the container build never hard-fails on that.
- Bumped the two Debian-source builds (`live-build`, `debootstrap`) from
  ad-hoc bookworm-era git tags to the exact tags trixie itself ships
  (`debian/1%20250505+deb13u1` and `1.0.141`); verified the two local
  patches (`0001-save-package-info.patch` for live-build's manifest/SBOM
  hook, and the debootstrap `/proc`/`/sys` docker-mount fix) still apply
  cleanly with `patch --dry-run` against those tags.
- FPM comment corrected: it was labeled "for e.g. Intel QAT drivers" but is
  actually used for `unionfs-fuse` (the only fpm-built package we still
  keep in `scripts/package-build/`).

### Package name changes verified against trixie (`qa.debian.org/madison`, `s=trixie`/`s=trixie-backports`)

| Old (bookworm-era) | New (trixie) | Where |
|---|---|---|
| `qemu-kvm` | removed - `qemu-system-x86`/`qemu-system-arm` already provide KVM accel | `docker/Dockerfile` |
| `qemu-system-aarch64` | `qemu-system-arm` (Debian merged the two) | `docker/Dockerfile` |
| `python3-pep8`, `python3-unittest2`, `python3-contextlib2` | gone from trixie; moot, whole cloud-init test-dep block removed | `docker/Dockerfile` |
| `linux-kbuild-6.1` | no longer included in debootstrap's minbase `--include`; package no longer needed since we don't build kernel modules during bootstrap | `build-vyos-image` |
| `vyos-linux-firmware` | `firmware-linux` (non-free-firmware) | `data/architectures/amd64.toml` |
| `isc-kea-dhcp4-server` etc. | `kea-dhcp4-server`, `kea-dhcp6-server`, `kea-dhcp-ddns-server`, `kea-ctrl-agent` | not yet renamed anywhere in this milestone - see Open items |

Everything else installed by `docker/Dockerfile` and `data/live-build-config/package-lists/*.list.chroot`
was checked individually against `s=trixie` and confirmed present
(dialog, bash-completion, debhelper, live-build, python3-fastapi,
python3-pyroute2, the whole vyos-1x build-dep list, qemu-system-x86,
grub2/grub-pc/grub-efi-*, u-boot-tools, debmake, etc.).

### `data/defaults.toml`

- `debian_distribution`: `bookworm` -> `trixie`.
- `vyos_mirror`: `https://packages.vyos.net/repositories/rolling` ->
  `https://ericgullickson.github.io/fbtech-nos`.
- `vyos_branch` / `release_train`: `rolling` -> `fbtech` (labels only - see
  "Fixing the `vyos_branch` conflation" below).
- `kernel_version` removed; `kernel_flavor`: `vyos` -> `amd64`. This is now
  the live-build *flavour* name for Debian's `linux-image-amd64`
  metapackage, not a specific kernel version - see below.
- `website_url`/`support_url`/`bugtracker_url`/`documentation_url`/`project_news_url`
  repointed at `github.com/ericgullickson/fbtech-nos`.
- Added `vyos_mirror_suite`, `vyos_mirror_origin`, `component_git_org`,
  `component_git_branch`, and a `[component_repos]` table - see next
  section.

### Fixing the `vyos_branch` conflation (follow-up)

The first pass at this milestone set `vyos_branch = "fbtech"` and hit an
immediate dry-run failure (see "Where the trixie ISO dry-run stopped"):
`build-vyos-image` was using that single setting for three unrelated
things that happen to share a name in upstream VyOS but not in this fork.
Investigated with `grep -n "GitCommandError\|vyos-1x\|checkout"
scripts/image-build/build-vyos-image`, which turned up all three call
sites in `build()`:

1. **The apt suite of the overlay/VyOS package mirror** (`deb {vyos_mirror}
   {vyos_branch} main`, near the end of `build()`).
2. **The git branch checked out for `vyos-1x`**, right at the top of
   `build()`, before `lb config` is ever touched. This is *not* optional
   and not just for a version string: the very next lines add
   `build/vyos-1x/python` to `sys.path` and then `import utils` /
   `import raw_image` (`scripts/image-build/utils.py`,
   `scripts/image-build/raw_image.py`), both of which `import vyos`
   directly out of that checkout - `vyos.utils.process.call`/`rc_cmd` is
   what the `cmd()`/`rc_cmd()` helpers used for *every* shell command in
   this script (including `lb config` and `lb build` themselves) actually
   call; `vyos.defaults` supplies the `directories`/`activation_hint`/
   `activation_init` constants; `vyos.template` is used by
   `raw_image.py`. There is no lazy/optional path here - the script
   cannot do anything at all without a working vyos-1x checkout.
3. **The apt pin's `Pin: release n=...` value**, in the `lb config`
   section. This one wasn't even mentioned as broken by the original
   dry-run (it never got that far), but decoupling suite from label would
   have silently broken it too: it was pinning by `release_train`
   ("fbtech"), which no longer matches the actual suite name once (1) uses
   a separate `vyos_mirror_suite`.

Fix: introduced `vyos_mirror_suite = "trixie"` for (1),
`component_git_org = "ericgullickson"` / `component_git_branch = "fbtech"`
/ a `[component_repos]` table (mapping `vyos-1x` -> the actual fork name
`fbtech-nos-1x`, and the other four known component forks for future use)
for (2), and kept `vyos_branch`/`release_train = "fbtech"` as pure labels
(`os-release` strings, ISO version metadata) used nowhere else. The
`vyos-1x` checkout now clones `https://github.com/{component_git_org}/
{component_repos['vyos-1x']}` (i.e. `ericgullickson/fbtech-nos-1x`) at
`component_git_branch` (`fbtech`) - both env-overridable
(`VYOS1X_REPO_URL`, and a new `VYOS1X_REPO_BRANCH`) as before.

For (3), pinning was switched from suite/codename (`n=`) to **Origin**
(`o=`): the package-build pipeline's reprepro config
(`.github/workflows/build-packages.yml` on `main`) publishes `Codename:
trixie` for our own repo - the same string Debian's own main archive
reports as its Codename. An `n=trixie` pin would therefore match Debian's
ordinary trixie packages too, not just ours, silently defeating the whole
point of pinning. `Origin: fbtech-nos` (also set by that reprepro config)
is unique to our repo, so both the dynamically-generated pin file
(`build-vyos-image`, `VYOS_PIN_FILE`) and the static
`data/live-build-config/archives/fbtech-nos.pref.chroot` now pin
`o={vyos_mirror_origin}` (`o=fbtech-nos`) instead. This is also how
`fbtech-nos.pref.chroot` satisfies "pin our repo above Debian for the
packages we override" (e.g. a self-built `bash-completion`, if one is
ever published under our repo) - the pin is unconditional on package name
(`Package: *`), so it applies to anything we publish, without needing a
per-package pin entry.

`data/live-build-config/archives/fbtech-nos.key.chroot` was replaced with
the real signing key from `origin/main:overlay/fbtech-nos-archive-keyring.asc`
(the package-build pipeline's actual published key), replacing the earlier
TODO placeholder.

### Kernel: self-built VyOS kernel -> Debian's `linux-image-amd64`

`build-vyos-image`'s `lb config` invocation:

- `--linux-flavours "{{kernel_flavor}}"` now renders `amd64` instead of `vyos`.
- `--linux-packages "linux-image-{{kernel_version}}"` (which rendered
  `linux-image-6.18.48`, VyOS's own package name) is now the literal
  `--linux-packages "linux-image"`, so combined with the flavour above
  live-build asks for the real Debian metapackage `linux-image-amd64`.
- Added `data/live-build-config/archives/trixie-backports.pref.chroot`
  (pins `linux-image-amd64` and `kea*` to `trixie-backports` at priority
  600, everything else in backports at -100) and
  `trixie-backports.list.chroot` (an explicit `deb ... trixie-backports
  main contrib non-free non-free-firmware` line; `lb config --backports
  true`, already set, should add an equivalent source on its own, so this
  is redundant-but-explicit rather than load-bearing).
- Deleted `data/live-build-config/archives/bookworm-backports.pref.chroot`
  (pinned `suricata`/`zabbix-agent2`, both dropped features).
- The kernel's actual version/ABI is whatever `linux-image-amd64` resolves
  to at build time (currently `7.1.x` from trixie-backports per the pin,
  `6.12.x` from trixie main if the backports pin is ever removed); nothing
  in the build scripts or hooks hardcodes a version number for it. Hooks
  that need to know which kernel got installed (`19-kernel_symlinks.*`,
  `17-gen_initramfs.chroot`) already discovered it from `/boot/vmlinuz-*` /
  `ls /boot` glob patterns before this change and needed no code changes,
  only a stale comment fix in `17-gen_initramfs.chroot` (it referenced a
  `kernel_version` setting that no longer exists).

### Secure Boot: VyOS shim signing dropped

Per `docs/FORK-PLAN.md`'s decision to drop the VyOS Secure Boot shim and
use Debian's own signed shim/grub/kernel as-is:

- Deleted `data/live-build-config/hooks/live/93-sb-sign-kernel.chroot`
  (signed kernel modules with a VyOS MOK key via `sbsign`).
- Deleted `data/certificates/vyos-prod-2025-linux.pem` (the VyOS Secure
  Boot public cert it consumed) and the `"Secure Boot - Copy public Keys
  to image"` block in `build-vyos-image` that copied `data/certificates`
  into `includes.chroot/var/lib/shim-signed/mok` - both existed only to
  feed that hook.
- Removed `sbsigntool` from `docker/Dockerfile` (only consumer was the
  deleted hook).
- `scripts/package-build/shim-signed/` was deleted as part of the overlay
  trim (see below) for the same reason.

### `data/architectures/amd64.toml`

Removed `vyos-drivers-realtek-r8152`, `vyos-linux-firmware`,
`vyos-intel-qat`, `vyos-intel-ixgbe`, `vyos-intel-ixgbevf`,
`vyos-intel-i40e`, `vyos-intel-ice`, `vyos-intel-iavf`,
`vyos-ipt-netflow` (all built from `scripts/package-build/linux-kernel/`,
now deleted). Added `firmware-linux` (non-free-firmware, already enabled in
`debian_archive_areas`). Kept `grub2`, `grub-pc`, `intel-microcode`,
`amd64-microcode`. In-tree `r8169`/`r8152` and `igb`/`ixgbe`/`i40e`/`ice`/
`iavf` drivers from the stock kernel replace the out-of-tree builds; see
Open items for what is lost.

### Hooks audit (`data/live-build-config/hooks/live/`)

Checked every hook for kernel-version or VyOS-only-package assumptions:

| Hook | Verdict |
|---|---|
| `19-kernel_symlinks.chroot`/`.binary` | No change. Already glob-based (`vmlinuz-*`/`initrd.img-*`), works with any installed kernel. |
| `93-sb-sign-kernel.chroot` | **Deleted.** Secure Boot shim dropped. |
| `17-gen_initramfs.chroot` | Comment fixed (see above); logic already glob-based, no functional change. |
| `12-udev-initramfs.chroot` | No change. Generic initramfs-tools sed fix, unrelated to kernel source. |
| `30-mpls_modules.chroot` | No change. `mpls_gso`/`mpls_iptunnel`/`mpls_router` are in-tree in Debian's kernel too; FRR/MPLS routing is kept. |
| `30-strongswan-configs.chroot` | No change. strongswan is kept; disables the Cisco Unity/farp plugins and adds IKE-name logging, none of that is VyOS-kernel- or VyOS-package-specific. |
| `24-efi_packages.chroot` | No change. Already a no-op (`exit 0` as its first line); left as dead code, out of scope to clean up further here. |
| `100-remove-dropbear-keys.chroot` | No change. dropbear is a plain Debian package on trixie too (VyOS's PAM-patched dropbear build is dropped from the overlay; see Open items). |
| `18-enable-disable_services.chroot` | **Not changed, flagged as an open item below.** Lists `systemctl disable` for services tied to dropped packages (hsflowd, telegraf, zabbix-agent2, suricata, vpp, ocserv, ModemManager, hostapd, LCDd/lcdproc, owamp-server/twamp-server) and still uses the old `isc-kea-dhcp4-server`/`isc-kea-dhcp6-server`/`isc-kea-dhcp-ddns-server` unit names instead of Debian's `kea-dhcp4-server` etc. `systemctl disable` on a missing/renamed unit does not fail the hook (no `set -e`, and live-build tolerates the non-zero exit), so this is cosmetic/noisy rather than build-breaking, but it belongs to the `vyos-1x`/package-rename work in milestone 4, not this milestone's data/Dockerfile scope. |
| `07-apt.chroot`, `15-sources_list.chroot`, `16-fuse.chroot`, `09-live.chroot`, `03-root_bash_completion.chroot`, `40-init-geoip-database.chroot`, `08-sysconf.chroot`, `92-strip-symbols.chroot`, `00-manifest.binary`, `00-mk_buildid.chroot`, `01-interfaces.chroot`, `01-live-serial.binary`, `04-locale.chroot`, `20-systemd_target.chroot`, `21-pam_mkhomedir.chroot`, `23-config_mkdir.chroot`, `40-init-cracklib-db.chroot`, `90-localepurge.chroot`, `95-serial.chroot`, `14-acpid.chroot`, `11-busybox.chroot` | No change. Reviewed; none reference a kernel version or a dropped/renamed package. |

### `build-vyos-image` (`scripts/image-build/build-vyos-image`)

- `--debootstrap-options`: dropped `linux-kbuild-6.1` from `--include=`
  (was only useful for building kernel modules during bootstrap; unused now).
- `--linux-flavours`/`--linux-packages`: see Kernel section above.
- Removed the Secure Boot cert copy block (see above).
- `component_supplier()` (CycloneDX SBOM generation): the
  `linux-kernel-cataloger` branch attributed every kernel-module SBOM
  component to VyOS ("VyOS compiles every one itself for this exact kernel
  build"). That is no longer true - the kernel is Debian's stock build -
  so that branch now returns a new `debian_supplier` (`{"name": "Debian",
  "url": ["https://www.debian.org"]}`) instead of `vyos_supplier`. The
  top-level SBOM `metadata.supplier`/`metadata.authors` (who built the
  *image*) were left as `"VyOS Networks"`/`"VyOS maintainers and
  contributors"` - that is a broader rebrand question for milestone 4/5,
  not a kernel-dependency one, and is flagged below.

### `scripts/package-build/`

Deleted every package directory not in the overlay list from
`docs/FORK-PLAN.md`: `amazon-cloudwatch-agent`, `amazon-ssm-agent`,
`aws-gwlbtun`, `bash-completion`, `blackbox_exporter`, `ddclient`,
`dropbear`, `ethtool`, `frr` (including all 12 patches, notably BGP-LS),
`frr_exporter`, `hostap`, `hsflowd`, `iproute2`, `isc-dhcp`, `isc-kea`,
`keepalived`, `libhtp`, `libnss-mapuser`, `libpam-radius-auth`,
`linux-kernel` (kernel + all out-of-tree driver/DKMS build scripts and
config fragments), `ndppd`, `net-snmp`, `netfilter`, `node_exporter`,
`openssl`, `openvpn-otp`, `owamp`, `podman`, `pyhumps`, `radvd`,
`shim-signed`, `squid`, `strongswan` (including the DMVPN-enabling vici
patches), `tacacs`, `telegraf`, `udp-broadcast-relay`, `vpp`, `waagent`,
`wide-dhcpv6`, `xen-guest-agent`, `zerotier-one`.

Kept: `build.py` (generic per-package build driver, unmodified), `vyos-1x`
(still points at unmodified upstream `vyos/vyos-1x` - forking it is
milestone 4), `unionfs-fuse` (kept building from upstream v3.6 via fpm,
per `docs/FORK-ANALYSIS.md` section 8's recommendation).

`README.md` was checked for references to any of the deleted packages;
it has none (it only describes the top-level repo layout in generic
terms), so no changes were needed there.

### `.github/workflows/build-container.yml` (new)

Builds `docker/Dockerfile` for `linux/amd64` and pushes to
`ghcr.io/ericgullickson/fbtech-nos-build:trixie` (and a
`:trixie-<sha>` tag) on `workflow_dispatch` and on push to `main`/
`trixie-base` when `docker/**` changes. Uses `docker/login-action` with
`GITHUB_TOKEN` (`permissions: contents: read, packages: write`). Includes a
best-effort step to flip the package to public via
`gh api -X PATCH /user/packages/container/fbtech-nos-build/visibility`;
this is expected to fail with `GITHUB_TOKEN` (that endpoint needs a PAT
with `admin:packages`/`delete:packages` scope owned by the package owner
for a personal package), so the step is `continue-on-error: true` and logs
a warning with a link to set it manually instead of failing the build.

### `.github/workflows/trixie-iso-dryrun.yml` (new)

`workflow_dispatch`-only, `timeout-minutes: 60`, `continue-on-error: true`,
runs inside `ghcr.io/ericgullickson/fbtech-nos-build:trixie` with
`--privileged` and attempts:

```
sudo --preserve-env ./build-vyos-image --architecture amd64 \
  --build-by ci@fbtech-nos --build-type release --version dryrun \
  --vyos-mirror https://packages.vyos.net/repositories/rolling/ generic
```

exactly as specified for this milestone, captures the full log as an
artifact, and writes a step summary with the tail of the log plus any
lines matching common apt/dependency failure patterns.

## Verified

- `build-container.yml` run (push-triggered):
  https://github.com/ericgullickson/fbtech-nos/actions/runs/33651860230 -
  built and pushed `ghcr.io/ericgullickson/fbtech-nos-build:trixie` and
  `:trixie-5c4368262fa0a76dd47c26a1c05ce2879290410e` successfully on the
  first try (no iteration needed).
- Package visibility: **public**, confirmed by pulling the manifest
  anonymously (`curl https://ghcr.io/token?scope=repository:ericgullickson/fbtech-nos-build:pull`
  then `GET /v2/ericgullickson/fbtech-nos-build/tags/list` with that token
  returned `200` and both tags with no credentials at all). This is
  because packages published from a public repository via `GITHUB_TOKEN`
  default to public visibility. The workflow's own
  `gh api -X PATCH .../visibility` step got a `404` as anticipated
  (`GITHUB_TOKEN` cannot administer package visibility) - harmless since
  the package was already public.
- `trixie-iso-dryrun.yml` run 1 (before the `vyos_branch` fix):
  https://github.com/ericgullickson/fbtech-nos/actions/runs/33653090330
  (triggered via a temporary `push` trigger, since GitHub will not let a
  `workflow_dispatch`-only workflow be dispatched via API/CLI until it
  exists on the default branch - reverted to `workflow_dispatch`-only
  immediately after this run, then dispatched normally for run 2 below
  once the workflow was registered). Failed immediately at vyos-1x
  checkout - see "Where the trixie ISO dry-run stopped".
- `trixie-iso-dryrun.yml` run 2 (after the fix, component forks, and
  published apt repo all existed):
  https://github.com/ericgullickson/fbtech-nos/actions/runs/33665322607.
  Confirmed the `vyos_branch` fix works (no checkout failure this time)
  and that debootstrap + Debian package installation via live-build both
  complete successfully on trixie; failed later, fetching the overlay
  repo's Release file - see "Where the trixie ISO dry-run stopped" for
  the full analysis.
- The `live-build`/`debootstrap` source patches used in `docker/Dockerfile`
  were confirmed (via `patch --dry-run`) to still apply cleanly to the
  exact tags trixie ships (`debian/1%20250505+deb13u1`,
  `1.0.141`), locally, against a live clone of both salsa repos.
- All package names referenced by `docker/Dockerfile`,
  `data/architectures/amd64.toml`, and
  `data/live-build-config/package-lists/*.list.chroot` were checked
  individually against `qa.debian.org/madison.php?s=trixie` (and
  `s=trixie-backports` for `linux-image-amd64`/`kea`).
- `build-vyos-image` still parses and imports cleanly
  (`python3 -m py_compile`) after the edits.

## Not verified

- No image has been booted; `make testc` / the smoketest suite has not run.
  This milestone cannot produce a booting image - the overlay (`vyos-1x`
  etc.) is not published for trixie yet.
- The `docker/patches/live-build/0001-save-package-info.patch` and the
  debootstrap docker-mount patch were only confirmed to *apply* cleanly,
  not to actually build correctly on trixie's newer build toolchain
  (`dpkg-buildpackage`, debhelper compat level, etc.) - that only gets
  proven by the `build-container.yml` run.
- Whether `firmware-linux` alone is sufficient for common NIC firmware
  needs (some vendors ship firmware in more specific packages, e.g.
  `firmware-realtek`) was not checked against real hardware.
- Whether trixie's in-tree `r8169`/`r8152` and `ixgbe`/`i40e`/`ice`/`iavf`
  drivers cover the same hardware range as VyOS's out-of-tree builds.

## Where the trixie ISO dry-run stopped, and why

Two runs so far, in order:

### Run 1 (before the `vyos_branch` fix): failed at vyos-1x checkout

```
E: Could not retrieve vyos-1x from branch fbtech: GitCommandError(['git', 'checkout', 'fbtech'], 1, b"error: pathspec 'fbtech' did not match any file(s) known to git", b'')
```

Run: https://github.com/ericgullickson/fbtech-nos/actions/runs/33653090330.
Stopped immediately, before live-build (or even `lb config`) ever ran. Root
cause and fix: see "Fixing the `vyos_branch` conflation" above - `vyos-1x`
was still unforked upstream at that point (no `fbtech` branch existed).

### Run 2 (after the fix, and after the component forks/apt repo existed): failed fetching the overlay repo's Release file

```
Ign:37 https://packages.vyos.net/repositories/rolling trixie InRelease
Err:38 https://packages.vyos.net/repositories/rolling trixie Release
  404  Not Found [IP: 172.67.73.83 443]
...
E: The repository 'https://packages.vyos.net/repositories/rolling trixie Release' does not have a Release file.
...
E: An unexpected failure occurred, exiting...
```

which surfaces up through `build-vyos-image` as:

```
Traceback (most recent call last):
  File ".../build-vyos-image", line 994, in <module>
    build()
  File ".../build-vyos-image", line 818, in build
    cmd("lb build 2>&1")
  File ".../scripts/image-build/utils.py", line 89, in cmd
    raise OSError(f"Command '{command}' failed")
OSError: Command 'lb build 2>&1' failed
```

Run: https://github.com/ericgullickson/fbtech-nos/actions/runs/33665322607
(`trixie-dryrun-log` artifact has the full ~1200-line log).

**This got much further than run 1**: `lb build` ran debootstrap for the
trixie base and successfully installed the full `vyos-base`/`vyos-utils`
package lists plus everything `apt-get`-installable from `debian_mirror`
(trixie main/contrib/non-free/non-free-firmware) and `trixie-backports`
(confirmed dozens of `Get:`/`I: Configuring ...` lines for ordinary
Debian packages completing normally). It stopped when live-build's chroot
apt update reached the *overlay* package repository entry.

**Root cause: the dry-run command's `--vyos-mirror` doesn't serve the
suite our config now asks for.** The milestone brief's dry-run command is
fixed as `--vyos-mirror https://packages.vyos.net/repositories/rolling/`
(VyOS's own public mirror). Combined with `vyos_mirror_suite = "trixie"`
(correct now - see above), `build-vyos-image` generates
`deb https://packages.vyos.net/repositories/rolling trixie main` - but
that mirror only has ever published a `rolling` suite, not `trixie`, so
there is no `dists/trixie/Release` there and apt 404s on it. Live-build
treats any configured-source fetch failure during chroot apt update as
fatal (`E: An unexpected failure occurred, exiting...`), which aborts `lb
build` entirely - `build-vyos-image`'s `cmd()` wrapper then raises the
`OSError` above and the whole script exits.

**This did not reach dependency resolution on `vyos-1x` at all** (the
milestone brief's "expected to fail when installing vyos-1x" scenario),
so there is no list of missing/unsatisfiable `vyos-1x` dependencies to
report from this run - the failure is one level earlier, at the apt
*source* level, before apt gets to resolving any package's dependencies.
No mirror currently serves both `vyos-1x` and a suite literally named
`trixie`: VyOS's public mirror has `vyos-1x` but only under `rolling`; our
own repo (`https://ericgullickson.github.io/fbtech-nos`) serves suite
`trixie` (matching `vyos_mirror_suite`) but does not have `vyos-1x`
published yet (milestone 2's package-build pipeline is a separate,
ongoing effort). Getting the actual "install vyos-1x against trixie"
dependency-resolution signal needs either: (a) re-running the dry-run
with `--vyos-mirror` pointed at our own repo once it has *something*
published (even a partial overlay set would show real apt behaviour), or
(b) `--custom-apt-entry`/`--custom-apt-key` to add a second source that
has both `vyos-1x` and a `trixie` suite. Neither was attempted in this
session; it's the natural next step once milestone 2 has published
anything.

**Minor, confirmed-harmless finding**: apt logged repeated
`W: Target Packages (.../Packages) is configured multiple times in
/etc/apt/sources.list:7 and /etc/apt/sources.list.d/trixie-backports.list:10`
warnings during this run. This confirms the redundancy noted when
`data/live-build-config/archives/trixie-backports.list.chroot` was added
(`lb config --backports true` already adds an equivalent source
automatically) - it is genuinely harmless (a `W:` warning, not an `E:`
error, and did not block or slow the actual package installs), but noisy
enough that removing the static `trixie-backports.list.chroot` and
relying solely on `--backports true` would be a reasonable follow-up
cleanup.

## Open items for milestone 4/5

1. ~~`vyos_branch`/apt-suite-naming mismatch`~~ **Fixed.** `vyos_mirror_suite
   = "trixie"` now matches what the package-build pipeline's reprepro
   config actually publishes (`Codename: trixie`), decoupled from
   `vyos_branch`/`release_train` (kept as pure labels) and from
   `component_git_branch` (the vyos-1x/component-fork git branch). See
   "Fixing the `vyos_branch` conflation" above. New follow-on item: **no
   mirror currently serves both `vyos-1x` and a `trixie` suite** (VyOS's
   public mirror only has a `rolling` suite; our own repo has `trixie` but
   no `vyos-1x` yet) - see "Where the trixie ISO dry-run stopped", run 2.
   Revisit once milestone 2 publishes anything.
2. ~~Real fbtech-nos apt signing key~~ **Fixed.**
   `data/live-build-config/archives/fbtech-nos.key.chroot` now has the
   real key from `origin/main:overlay/fbtech-nos-archive-keyring.asc`, and
   `fbtech-nos.pref.chroot` pins by `Origin: fbtech-nos` (`o=`) rather than
   suite name (`n=`), since our repo's `Codename: trixie` collides with
   Debian's own trixie Codename and an `n=` pin would have matched both.
3. **`vyos-1x` Depends that trixie cannot satisfy**, from
   `docs/FORK-ANALYSIS.md` section 4/item 5, still apply verbatim since
   `vyos-1x`'s `debian/control` has not been touched yet (milestone 4):
   `podman >= 5.8` (trixie has 5.4.2 - moot once podman/containers support
   is dropped from `debian/control`), `strongswan >= 6.0.6` (trixie has
   6.0.1 - strongswan/IPsec is kept, so this needs either a version-floor
   relaxation or strongswan from sid/backports), `telegraf >= 1.20` (not
   packaged in Debian at all - moot once dropped). Kea package names
   (`isc-kea-dhcp4` -> `kea-dhcp4-server` etc.) also still need renaming in
   `debian/control` and in the Jinja2/hook logic that references them
   (starting with `18-enable-disable_services.chroot`, see below).
4. **`18-enable-disable_services.chroot`** still lists `systemctl disable`
   for services belonging to dropped packages (hsflowd, telegraf,
   zabbix-agent2, suricata, vpp, ocserv, ModemManager, hostapd,
   LCDd/lcdproc, owamp-server, twamp-server) and still uses the pre-rename
   `isc-kea-dhcp4-server`/`isc-kea-dhcp6-server`/`isc-kea-dhcp-ddns-server`
   unit names. Harmless today (missing-unit `systemctl disable` doesn't
   fail the hook) but should be trimmed/renamed alongside the `vyos-1x`
   `debian/control` work in milestone 4.
5. **bash-completion 2.16.** `scripts/package-build/bash-completion/` (the
   VyOS-pinned 2.8 build) was deleted per the overlay list, meaning
   `vyatta-bash` will meet trixie's stock bash-completion 2.16. Per
   `docs/FORK-ANALYSIS.md` section 4/item 1, this is expected to break the
   CLI completion engine and is explicitly called out there as "the one
   item that blocks even booting a usable CLI" - fixing `vyatta-bash`
   itself is milestone 4/5 work, not something this milestone's data/
   Dockerfile-only scope can address.
6. **unionfs-fuse is kept building**, but `vyatta-cfg` (which depends on
   it) is not yet forked/trimmed - both are milestone 4 scope. No action
   needed here beyond noting that `scripts/package-build/unionfs-fuse/`
   was deliberately kept as-is (per `docs/FORK-ANALYSIS.md` section 8).
7. **Firmware/driver coverage** for `firmware-linux` + in-tree drivers vs.
   VyOS's out-of-tree Intel/Realtek builds and `vyos-ipt-netflow` (replaced
   by nothing yet; `iptables-netflow-dkms` exists in trixie if netflow
   ends up wanted back) is unverified on real hardware (see "Not
   verified").
8. **SBOM/manifest branding.** `component_supplier()`'s top-level
   `metadata.supplier`/`metadata.authors` (`"VyOS Networks"`/`"VyOS
   maintainers and contributors"`) and the ISO's `--iso-application`/
   `--iso-volume`/`os_release` `ID=vyos` strings elsewhere in
   `build-vyos-image` were deliberately left alone in this milestone (out
   of scope: this is product branding/identity, not a kernel or
   Debian-base dependency) but will need a decision in milestone 4/5.
9. **Dry-run coverage.** Confirmed (run 2): debootstrap and ordinary
   Debian package installation via live-build both work on trixie. Still
   not exercised: apt dependency resolution for `vyos-1x` itself, and by
   extension the `debian/control` Depends issues in item 3 - that needs a
   `--vyos-mirror` (or `--custom-apt-entry`) that actually has `vyos-1x`
   published under a `trixie`-suite-compatible source once milestone 2
   exists.
10. **Redundant `trixie-backports` source (confirmed harmless).** Run 2
    logged repeated `W: Target Packages ... is configured multiple times`
    warnings between `--backports true`'s auto-generated source and the
    static `data/live-build-config/archives/trixie-backports.list.chroot`.
    Not build-breaking, but removing the static `.list.chroot` (keeping
    only `trixie-backports.pref.chroot` for the pin) would be a clean,
    low-risk follow-up.
